#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/alooz-vps-bot"
SERVICE="alooz-vps-bot"
BOT_FILE="$APP_DIR/bot.py"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash alooz-installer.sh"
  exit 1
fi

echo "======================================"
echo "       ALOOZ HOSTING VPS BOT"
echo "======================================"
read -r -s -p "Enter Discord Bot Token: " BOT_TOKEN
echo
read -r -p "Enter Admin Discord User ID: " ADMIN_ID
if [[ -z "$BOT_TOKEN" || ! "$ADMIN_ID" =~ ^[0-9]{15,22}$ ]]; then
  echo "Invalid token or Discord User ID."
  exit 1
fi

echo "[1/6] Installing KVM, libvirt and dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y python3 python3-venv python3-pip qemu-kvm libvirt-daemon-system \
  libvirt-clients virtinst qemu-utils cloud-image-utils genisoimage curl ca-certificates

systemctl enable --now libvirtd
systemctl enable --now libvirt-guests || true

if ! command -v virt-install >/dev/null 2>&1; then
  echo "virt-install installation failed."
  exit 1
fi

if ! (egrep -q '(vmx|svm)' /proc/cpuinfo); then
  echo "WARNING: CPU virtualization flags are not visible. This VPS may not support nested KVM."
fi

mkdir -p "$APP_DIR"/{images,instances}
chmod 700 "$APP_DIR"
if ! virsh net-info default >/dev/null 2>&1; then
  echo "ERROR: libvirt default NAT network is missing."
  echo "Check: virsh net-list --all"
  exit 1
fi
virsh net-start default >/dev/null 2>&1 || true
virsh net-autostart default >/dev/null 2>&1 || true

echo "[2/6] Creating isolated Python environment..."
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install "discord.py>=2.4,<3"

echo "[3/6] Writing bot application..."
cat > "$BOT_FILE" <<'PYBOT'
import os, re, json, sqlite3, secrets, string, asyncio, subprocess, hashlib
from pathlib import Path
import discord
from discord import app_commands
from discord.ext import commands

BASE = Path("/opt/alooz-vps-bot")
INSTANCES = BASE / "instances"
DB = BASE / "vps.sqlite3"
TOKEN = os.environ["DISCORD_BOT_TOKEN"]
ADMIN_ID = int(os.environ["ALOOZ_ADMIN_ID"])
IMAGE_URL = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
BASE_IMAGE = BASE / "images" / "ubuntu-24.04-cloud.img"

intents = discord.Intents.default()
bot = commands.Bot(command_prefix="!", intents=intents)

def db():
    c = sqlite3.connect(DB)
    c.execute("""CREATE TABLE IF NOT EXISTS vps
      (name TEXT PRIMARY KEY, owner INTEGER NOT NULL, ram INTEGER NOT NULL,
       cpu INTEGER NOT NULL, disk INTEGER NOT NULL, created TEXT DEFAULT CURRENT_TIMESTAMP)""")
    c.commit()
    return c

def run(*args, timeout=120):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout or "Command failed")[-1500:])
    return p.stdout.strip()

def is_admin(interaction):
    return interaction.user.id == ADMIN_ID

async def admin_only(interaction):
    if not is_admin(interaction):
        await interaction.response.send_message("⛔ এই command শুধু Admin ব্যবহার করতে পারবে।", ephemeral=True)
        return False
    return True

def safe_name(name):
    if not re.fullmatch(r"[a-zA-Z0-9-]{3,40}", name):
        raise ValueError("Invalid VM name.")
    return name

def owned_vms(user_id):
    with db() as c:
        return c.execute("SELECT name,ram,cpu,disk FROM vps WHERE owner=? ORDER BY created DESC", (user_id,)).fetchall()

async def ensure_image():
    if not BASE_IMAGE.exists():
        BASE_IMAGE.parent.mkdir(parents=True, exist_ok=True)
        run("curl", "-fL", "--retry", "3", IMAGE_URL, "-o", str(BASE_IMAGE), timeout=900)

def create_vm(name, owner, ram=1024, cpu=1, disk=10):
    safe_name(name)
    if ram != 1024 or cpu != 1 or disk != 10:
        raise ValueError("User plan is fixed at 1 GB RAM, 1 vCPU and 10 GB disk.")
    with db() as c:
        if c.execute("SELECT 1 FROM vps WHERE owner=?", (owner,)).fetchone():
            raise ValueError("তোমার ইতিমধ্যে একটি VPS আছে। নতুন VPS-এর জন্য Admin-এর সাথে যোগাযোগ করো।")
        if c.execute("SELECT 1 FROM vps WHERE name=?", (name,)).fetchone():
            raise ValueError("VM name already exists.")
        total = c.execute("SELECT COUNT(*) FROM vps").fetchone()[0]
        if total >= 5:
            raise ValueError("Host-এর নিরাপদ VPS limit (5) পূর্ণ। Admin-এর সাথে যোগাযোগ করো।")
    meminfo = Path("/proc/meminfo").read_text()
    available_kb = int(re.search(r"MemAvailable:\s+(\d+)", meminfo).group(1))
    free_gb = __import__("shutil").disk_usage(BASE).free / (1024**3)
    if available_kb < 1536 * 1024 or free_gb < 12:
        raise ValueError("Host-এ পর্যাপ্ত free RAM বা disk নেই।")
    INSTANCES.mkdir(exist_ok=True)
    work = INSTANCES / name
    work.mkdir(mode=0o700)
    disk_path = work / "disk.qcow2"
    seed_path = work / "seed.iso"
    password = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(18))
    password_hash = run("openssl", "passwd", "-6", password)
    (work / "user-data").write_text(
        "#cloud-config\n"
        "users:\n"
        "  - name: ubuntu\n"
        "    groups: [sudo]\n"
        "    shell: /bin/bash\n"
        "    sudo: ALL=(ALL) NOPASSWD:ALL\n"
        "    lock_passwd: false\n"
        f"    passwd: '{password_hash}'\n"
        "ssh_pwauth: true\n"
        "disable_root: true\n"
        "package_update: true\n"
        "packages: [qemu-guest-agent]\n"
        "runcmd:\n"
        "  - systemctl enable --now qemu-guest-agent\n"
    )
    (work / "meta-data").write_text(f"instance-id: {name}\nlocal-hostname: {name}\n")
    run("qemu-img", "convert", "-f", "qcow2", "-O", "qcow2", str(BASE_IMAGE), str(disk_path), timeout=900)
    run("qemu-img", "resize", str(disk_path), f"{disk}G")
    run("genisoimage", "-output", str(seed_path), "-volid", "cidata", "-joliet", "-rock",
        str(work / "user-data"), str(work / "meta-data"))
    run("virt-install", "--name", name, "--memory", str(ram), "--vcpus", str(cpu),
        "--import", "--os-variant", "ubuntu24.04",
        "--disk", f"path={disk_path},format=qcow2,bus=virtio",
        "--disk", f"path={seed_path},device=cdrom",
        "--network", "network=default,model=virtio",
        "--graphics", "none", "--noautoconsole", "--autostart", timeout=900)
    with db() as c:
        c.execute("INSERT INTO vps(name,owner,ram,cpu,disk) VALUES(?,?,?,?,?)",
                  (name, owner, ram, cpu, disk))
    return password

async def deploy_for(interaction, owner_id, display_user):
    await ensure_image()
    name = f"alooz-{owner_id}-{secrets.token_hex(3)}"
    password = await asyncio.to_thread(create_vm, name, owner_id)
    try:
        user = await bot.fetch_user(owner_id)
        await user.send(
            f"🎉 **ALOOZ HOSTING VPS Ready**\n"
            f"VM: `{name}`\nOS: Ubuntu 24.04\nRAM: 1 GB | CPU: 1 vCPU | Disk: 10 GB\n"
            f"Username: `ubuntu`\nPassword: `{password}`\n"
            "Network: Private NAT (no public IP). Public SSH access is not configured.\n"
            "এখনই password পরিবর্তন করো: `passwd`"
        )
        dm = "Credentials তোমার DM-এ পাঠানো হয়েছে।"
    except discord.Forbidden:
        dm = "⚠️ DM বন্ধ থাকায় credentials পাঠানো যায়নি। Admin-এর সাথে যোগাযোগ করো।"
    await interaction.followup.send(f"✅ VPS তৈরি হয়েছে: `{name}`\n{dm}", ephemeral=True)

@bot.event
async def on_ready():
    try:
        synced = await bot.tree.sync()
        print(f"ALOOZ HOSTING online as {bot.user}; synced {len(synced)} commands")
    except Exception as e:
        print("Command sync error:", e)

@bot.tree.command(name="help", description="ALOOZ VPS Bot commands")
async def help_cmd(i: discord.Interaction):
    await i.response.send_message(
        "**User:** `/deploy`, `/myvps`, `/status`, `/start`, `/stop`, `/reboot`\n"
        "**Admin:** `/admin_vps`, `/admin_delete`, `/announce`, `/host_stats`",
        ephemeral=True)

@bot.tree.command(name="deploy", description="Deploy your Ubuntu 24.04 VPS (one per user)")
async def deploy(i: discord.Interaction):
    if not i.guild:
        await i.response.send_message("এই command server-এর ভিতরে ব্যবহার করো।", ephemeral=True); return
    if owned_vms(i.user.id):
        await i.response.send_message("তোমার একটি VPS ইতিমধ্যে আছে।", ephemeral=True); return
    await i.response.defer(ephemeral=True, thinking=True)
    try:
        await deploy_for(i, i.user.id, str(i.user))
    except Exception as e:
        await i.followup.send(f"❌ Deploy failed: `{str(e)[:900]}`", ephemeral=True)

@bot.tree.command(name="myvps", description="Show your VPS")
async def myvps(i: discord.Interaction):
    rows = owned_vms(i.user.id)
    if not rows:
        await i.response.send_message("তোমার কোনো VPS নেই। `/deploy` ব্যবহার করো।", ephemeral=True); return
    msg = "\n".join(f"`{r[0]}` — {r[1]} MB RAM, {r[2]} CPU, {r[3]} GB Disk" for r in rows)
    await i.response.send_message(msg, ephemeral=True)

async def user_vm_action(i, action):
    rows = owned_vms(i.user.id)
    names = [r[0] for r in rows]
    if not names:
        await i.response.send_message("তোমার কোনো VPS নেই।", ephemeral=True); return
    name = names[0]
    try:
        await asyncio.to_thread(run, "virsh", action, name)
        await i.response.send_message(f"✅ `{name}`: {action} command completed.", ephemeral=True)
        try: await i.user.send(f"ALOOZ VPS update: `{name}` → `{action}` completed.")
        except discord.Forbidden: pass
    except Exception as e:
        await i.response.send_message(f"❌ {str(e)[:900]}", ephemeral=True)

@bot.tree.command(name="start", description="Start your VPS")
async def start_cmd(i: discord.Interaction): await user_vm_action(i, "start")
@bot.tree.command(name="stop", description="Shutdown your VPS")
async def stop_cmd(i: discord.Interaction): await user_vm_action(i, "shutdown")
@bot.tree.command(name="reboot", description="Reboot your VPS")
async def reboot_cmd(i: discord.Interaction): await user_vm_action(i, "reboot")

@bot.tree.command(name="status", description="Check your VPS status")
async def status_cmd(i: discord.Interaction):
    rows = owned_vms(i.user.id)
    if not rows:
        await i.response.send_message("তোমার VPS নেই।", ephemeral=True); return
    name = rows[0][0]
    try: state = await asyncio.to_thread(run, "virsh", "domstate", name)
    except Exception as e: state = str(e)[:300]
    await i.response.send_message(f"VM: `{name}`\nStatus: **{state}**\nNetwork: Private NAT; no public IP.", ephemeral=True)

@bot.tree.command(name="admin_vps", description="Admin: list all VPS")
async def admin_vps(i: discord.Interaction):
    if not await admin_only(i): return
    with db() as c: rows = c.execute("SELECT name,owner,ram,cpu,disk FROM vps ORDER BY created DESC").fetchall()
    msg = "\n".join(f"`{r[0]}` owner `{r[1]}` — {r[2]}MB/{r[3]}CPU/{r[4]}GB" for r in rows) or "No VPS."
    await i.response.send_message(msg[:1900], ephemeral=True)

@bot.tree.command(name="admin_delete", description="Admin: delete a VM by exact name")
@app_commands.describe(vm_name="Exact VM name")
async def admin_delete(i: discord.Interaction, vm_name: str):
    if not await admin_only(i): return
    try:
        name = safe_name(vm_name)
        with db() as c: row = c.execute("SELECT owner FROM vps WHERE name=?", (name,)).fetchone()
        if not row:
            await i.response.send_message("VM not found in bot database.", ephemeral=True); return
        try: await asyncio.to_thread(run, "virsh", "destroy", name)
        except Exception: pass
        await asyncio.to_thread(run, "virsh", "undefine", name, "--remove-all-storage")
        import shutil
        shutil.rmtree(INSTANCES / name, ignore_errors=True)
        with db() as c: c.execute("DELETE FROM vps WHERE name=?", (name,))
        await i.response.send_message(f"🗑️ Deleted `{name}`.", ephemeral=True)
        try:
            u = await bot.fetch_user(row[0]); await u.send(f"Admin deleted your VPS `{name}`.")
        except Exception: pass
    except Exception as e:
        await i.response.send_message(f"Delete failed: `{str(e)[:900]}`", ephemeral=True)

@bot.tree.command(name="announce", description="Admin: DM an announcement to VPS users")
@app_commands.describe(message="Announcement text")
async def announce(i: discord.Interaction, message: str):
    if not await admin_only(i): return
    with db() as c: ids = [r[0] for r in c.execute("SELECT DISTINCT owner FROM vps")]
    await i.response.defer(ephemeral=True)
    sent = 0
    for uid in ids:
        try:
            u = await bot.fetch_user(uid); await u.send(f"📢 **ALOOZ HOSTING Announcement**\n{message}")
            sent += 1
        except Exception: pass
    await i.followup.send(f"Announcement DM sent to {sent}/{len(ids)} VPS users.", ephemeral=True)

@bot.tree.command(name="host_stats", description="Admin: show Host resource usage")
async def host_stats(i: discord.Interaction):
    if not await admin_only(i): return
    try:
        mem = (Path("/proc/meminfo").read_text().splitlines()[0:2])
        disk = await asyncio.to_thread(run, "df", "-h", "/")
        with db() as c: count = c.execute("SELECT COUNT(*) FROM vps").fetchone()[0]
        await i.response.send_message(f"Tracked VPS: **{count}**\n`{mem[0]}`\n`{mem[1]}`\n```{disk[:1200]}```", ephemeral=True)
    except Exception as e: await i.response.send_message(f"Stats error: {e}", ephemeral=True)

db()
bot.run(TOKEN)
PYBOT
chmod 700 "$BOT_FILE"

echo "[4/6] Saving private bot configuration..."
umask 077
cat > "$APP_DIR/.env" <<EOF
DISCORD_BOT_TOKEN=$BOT_TOKEN
ALOOZ_ADMIN_ID=$ADMIN_ID
EOF
unset BOT_TOKEN

echo "[5/6] Creating systemd service..."
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=ALOOZ HOSTING Discord VPS Deploy Bot
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/python $BOT_FILE
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE"

echo "[6/6] Checking service..."
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  echo
  echo "======================================"
  echo " ALOOZ HOSTING BOT INSTALLED!"
  echo "======================================"
  echo "Service: $SERVICE"
  echo "Logs: journalctl -u $SERVICE -f"
  echo "Restart: systemctl restart $SERVICE"
  echo "Status: systemctl status $SERVICE"
else
  echo "Bot did not start. Check logs:"
  journalctl -u "$SERVICE" -n 60 --no-pager
  exit 1
fi
