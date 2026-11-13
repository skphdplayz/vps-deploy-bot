#!/usr/bin/env bash
# ALOOZ HOSTING VPS bot - one-command installer for Debian/Ubuntu.
#
# SINGLE-FILE VERSION: every bot file is embedded below, so this is the only
# file you need to upload to GitHub. Nothing else is downloaded or cloned.
#
# One click (as root):
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/skphdplayz/vps-deploy-bot/main/install.sh)
#
# Re-running it rewrites the bot code and restarts it (your .env is kept).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/alooz-bot}"
SERVICE="alooz-bot"
PORT_START=20000
PORT_END=20999

# ----------------------------------------------------------------------
# Animated banner (pure bash, no dependencies)
# ----------------------------------------------------------------------
PAL=(196 202 208 214 220 226 190 154 118 82 46 47 48 49 50 51 45 39 33 27 57 93 129 165 201 200 199 198 197)

show_banner() {
  local text="ALOOZ HOSTING" subtitle="VPS DEPLOY BOT  -  INSTALLER"
  local -a rows=("" "" "" "" "")
  local -A G=(
    [A]=" ### |#   #|#####|#   #|#   #"
    [L]="#    |#    |#    |#    |#####"
    [O]=" ### |#   #|#   #|#   #| ### "
    [Z]="#####|   # |  #  | #   |#####"
    [H]="#   #|#   #|#####|#   #|#   #"
    [S]=" ####|#    | ### |    #|#### "
    [T]="#####|  #  |  #  |  #  |  #  "
    [I]="#####|  #  |  #  |  #  |#####"
    [N]="#   #|##  #|# # #|#  ##|#   #"
    [G]=" ####|#    |#  ##|#   #| ### "
    [_]="   |   |   |   |   "
  )
  local n i ch x r row c line cols frame width
  local -a parts

  for ((n = 0; n < ${#text}; n++)); do
    ch="${text:n:1}"
    [ "$ch" = " " ] && ch="_"
    IFS='|' read -ra parts <<<"${G[$ch]}"
    for i in 0 1 2 3 4; do rows[i]+="${parts[i]} "; done
  done
  width=${#rows[0]}

  if [ ! -t 1 ]; then
    for r in 0 1 2 3 4; do echo "${rows[r]//#/█}"; done
    echo "$subtitle"
    return
  fi

  printf '\033[?25l'
  printf '\n\n\n\n\n\n'

  draw() { # draw SHIFT VISIBLE_COLUMNS
    local shift=$1 vis=$2
    printf '\033[5A'
    for r in 0 1 2 3 4; do
      row="${rows[r]}"
      line=""
      for ((x = 0; x < ${#row}; x++)); do
        c="${row:x:1}"
        if [ "$c" = "#" ] && [ "$x" -lt "$vis" ]; then
          line+=$'\033[38;5;'"${PAL[(x + shift) % ${#PAL[@]}]}"$'m█'
        else
          line+=" "
        fi
      done
      printf '\r%s\033[0m\033[K\n' "$line"
    done
  }

  # Reveal left to right, then rainbow shimmer.
  for ((frame = 0; frame <= 30; frame++)); do
    draw "$frame" $((width * frame / 30))
    sleep 0.03
  done
  for ((frame = 0; frame < 70; frame++)); do
    draw $((30 + frame)) "$width"
    sleep 0.04
  done

  # Typewriter subtitle.
  printf '\033[38;5;245m'
  for ((x = 0; x < width; x++)); do printf '═'; done
  printf '\033[0m\n'
  printf '%*s' $(((width - ${#subtitle}) / 2)) ''
  for ((n = 0; n < ${#subtitle}; n++)); do
    printf '\033[1;38;5;%sm%s\033[0m' "${PAL[(n * 2) % ${#PAL[@]}]}" "${subtitle:n:1}"
    sleep 0.03
  done
  printf '\n\033[?25h\n'
}

restore_terminal() { printf '\033[0m\033[?25h'; }
trap restore_terminal EXIT

show_banner
[ "${ALOOZ_BANNER_ONLY:-0}" = "1" ] && exit 0

# ----------------------------------------------------------------------
# Installer
# ----------------------------------------------------------------------
say() { printf '\033[1;36m[ALOOZ]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Please run as root (use sudo)."
command -v apt-get >/dev/null 2>&1 || die "Only Debian and Ubuntu are supported."

ask() { # ask VARIABLE "Question" [secret]
  local var="$1" text="$2" secret="${3:-}" value=""
  [ -r /dev/tty ] || die "No terminal available. Set $var as an environment variable and run again."
  if [ -n "$secret" ]; then
    read -r -s -p "$text: " value </dev/tty
    echo
  else
    read -r -p "$text: " value </dev/tty
  fi
  printf -v "$var" '%s' "$value"
}

say "Installing system packages (python3, docker)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl python3 python3-pip python3-venv docker.io >/dev/null
systemctl enable --now docker >/dev/null 2>&1 || true

say "Writing bot files to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/main.py" <<'__ALOOZ_EOF__'
"""Entry point: shows the animated ALOOZ HOSTING banner, then starts the bot."""

import logging
import sys

import config
from banner import play_banner


def main() -> None:
    play_banner()

    if not config.TOKEN:
        print("ERROR: DISCORD_TOKEN is missing. Copy .env.example to .env and fill it in.")
        sys.exit(1)
    if not (config.OWNER_ID or config.ADMIN_IDS):
        print("WARNING: OWNER_ID and ADMIN_IDS are empty, so nobody can use admin commands.")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    from bot import bot  # imported after the banner so the banner always shows first

    bot.run(config.TOKEN, log_handler=None)


if __name__ == "__main__":
    main()
__ALOOZ_EOF__
cat > "$INSTALL_DIR/bot.py" <<'__ALOOZ_EOF__'
"""ALOOZ HOSTING - Discord VPS deploy bot.

Admins deploy and manage every VPS. Members can only see and control the VPS
that belongs to them.
"""

import asyncio
import logging
import sqlite3
from typing import Optional

import discord
from discord import app_commands
from discord.ext import commands

import config
import docker_utils as dk
from database import Database

log = logging.getLogger("alooz")

db = Database(config.DB_PATH)
deploy_lock = asyncio.Lock()

STATUS_EMOJI = {
    "running": "\U0001F7E2",
    "exited": "\U0001F534",
    "created": "\U0001F7E1",
    "restarting": "\U0001F7E1",
    "paused": "\U0001F7E0",
    "missing": "⚫",
}


# ======================================================================
# Permission helpers
# ======================================================================
def is_owner(user_id: int) -> bool:
    return config.OWNER_ID != 0 and user_id == config.OWNER_ID


def is_admin(user_id: int) -> bool:
    return is_owner(user_id) or user_id in config.ADMIN_IDS or db.is_admin(user_id)


def admin_only():
    async def predicate(interaction: discord.Interaction) -> bool:
        if is_admin(interaction.user.id):
            return True
        raise app_commands.CheckFailure("Only ALOOZ HOSTING admins can use this command.")

    return app_commands.check(predicate)


def owner_only():
    async def predicate(interaction: discord.Interaction) -> bool:
        if is_owner(interaction.user.id):
            return True
        raise app_commands.CheckFailure("Only the bot owner can use this command.")

    return app_commands.check(predicate)


# ======================================================================
# Small utilities
# ======================================================================
def short(error: Exception, limit: int = 300) -> str:
    return str(error)[:limit]


async def reply(interaction: discord.Interaction, content: str = None, **kwargs) -> None:
    kwargs.setdefault("ephemeral", True)
    if interaction.response.is_done():
        await interaction.followup.send(content, **kwargs)
    else:
        await interaction.response.send_message(content, **kwargs)


async def get_vps_for(interaction: discord.Interaction, vps_id: int) -> Optional[sqlite3.Row]:
    """Return the VPS if the caller owns it or is an admin, otherwise reply and return None.

    Members get the same "not found" message for other people's VPS so they
    cannot probe which IDs exist.
    """
    row = db.get_vps(vps_id)
    if row is None or (row["owner_id"] != interaction.user.id and not is_admin(interaction.user.id)):
        await reply(interaction, f"VPS #{vps_id} was not found.")
        return None
    return row


def pick_port() -> Optional[int]:
    used = db.used_ports()
    for port in range(config.PORT_START, config.PORT_END + 1):
        if port not in used and dk.port_is_free(port):
            return port
    return None


def vps_embed(row: sqlite3.Row, status: str, *, show_password: bool = False, stats: dict = None) -> discord.Embed:
    color = discord.Color.green() if status == "running" else discord.Color.red()
    embed = discord.Embed(title=f"{config.BOT_NAME} • VPS #{row['id']}", color=color)
    suspended = " (suspended)" if row["suspended"] else ""
    embed.add_field(name="Status", value=f"{STATUS_EMOJI.get(status, STATUS_EMOJI['missing'])} {status}{suspended}")
    embed.add_field(name="Owner", value=f"<@{row['owner_id']}>")
    embed.add_field(name="OS", value=row["os_image"])
    embed.add_field(name="RAM", value=f"{row['ram_mb']} MB")
    embed.add_field(name="CPU", value=f"{row['cpu']:g} core(s)")
    embed.add_field(name="Disk", value=f"{row['disk_gb']} GB")
    embed.add_field(name="SSH", value=f"`ssh root@{config.SERVER_IP} -p {row['ssh_port']}`", inline=False)
    if show_password:
        embed.add_field(name="Root password", value=f"||{row['root_password']}||", inline=False)
    if stats:
        embed.add_field(
            name="Live usage",
            value=(
                f"CPU: {stats['cpu']}\nRAM: {stats['mem']}\n"
                f"Network: {stats['net']}\nDisk I/O: {stats['block']}\nProcesses: {stats['pids']}"
            ),
            inline=False,
        )
    embed.set_footer(text=config.BOT_NAME)
    return embed


class ConfirmView(discord.ui.View):
    def __init__(self, user_id: int, timeout: float = 30):
        super().__init__(timeout=timeout)
        self.user_id = user_id
        self.value: Optional[bool] = None

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user_id:
            await interaction.response.send_message("This prompt is not for you.", ephemeral=True)
            return False
        return True

    @discord.ui.button(label="Confirm", style=discord.ButtonStyle.danger)
    async def confirm(self, interaction: discord.Interaction, button: discord.ui.Button):
        self.value = True
        await interaction.response.edit_message(content="Working...", view=None)
        self.stop()

    @discord.ui.button(label="Cancel", style=discord.ButtonStyle.secondary)
    async def cancel(self, interaction: discord.Interaction, button: discord.ui.Button):
        self.value = False
        await interaction.response.edit_message(content="Cancelled.", view=None)
        self.stop()


# ======================================================================
# Bot
# ======================================================================
class AloozBot(commands.Bot):
    def __init__(self):
        super().__init__(command_prefix=commands.when_mentioned, intents=discord.Intents.default())

    async def setup_hook(self) -> None:
        await self.tree.sync()

    async def on_ready(self) -> None:
        log.info("Logged in as %s (%s)", self.user, self.user.id)
        await self.change_presence(activity=discord.Activity(type=discord.ActivityType.watching, name=config.BOT_NAME))


bot = AloozBot()


@bot.tree.error
async def on_app_command_error(interaction: discord.Interaction, error: app_commands.AppCommandError):
    if isinstance(error, app_commands.CheckFailure):
        message = str(error) or "You are not allowed to use this command."
    else:
        log.exception("Unhandled command error", exc_info=error)
        message = "Something went wrong. Please try again or contact an admin."
    try:
        await reply(interaction, message)
    except discord.HTTPException:
        pass


# ======================================================================
# Admin: deploy and fleet management
# ======================================================================
OS_CHOICES = [
    app_commands.Choice(name="Ubuntu 22.04", value="ubuntu:22.04"),
    app_commands.Choice(name="Ubuntu 24.04", value="ubuntu:24.04"),
    app_commands.Choice(name="Debian 12", value="debian:12"),
]


@bot.tree.command(name="deploy", description="[Admin] Create a VPS for a member")
@app_commands.describe(
    member="Member who will receive the VPS",
    ram_mb="RAM in MB (example: 1024)",
    cpu="CPU cores (example: 1 or 0.5)",
    disk_gb="Disk size in GB",
    os_image="Operating system",
)
@app_commands.rename(os_image="os")
@app_commands.choices(os_image=OS_CHOICES)
@admin_only()
async def deploy(
    interaction: discord.Interaction,
    member: discord.Member,
    ram_mb: app_commands.Range[int, 128, 262144],
    cpu: app_commands.Range[float, 0.1, 128.0],
    disk_gb: app_commands.Range[int, 1, 10000],
    os_image: app_commands.Choice[str] = None,
):
    if member.bot:
        await reply(interaction, "You cannot deploy a VPS for a bot account.")
        return
    image = os_image.value if os_image else OS_CHOICES[0].value
    await interaction.response.defer(ephemeral=True, thinking=True)

    async with deploy_lock:
        port = pick_port()
        if port is None:
            await interaction.followup.send("No free SSH ports are left in the configured range.", ephemeral=True)
            return
        vps_id = db.add_vps(member.id, ram_mb, float(cpu), disk_gb, port, dk.generate_password(), image)
        row = db.get_vps(vps_id)
        try:
            await dk.create_container(
                row["container"], image, ram_mb, float(cpu), disk_gb, port,
                row["root_password"], config.USE_DISK_LIMIT,
            )
        except dk.DockerError as exc:
            db.delete_vps(vps_id)
            await interaction.followup.send(f"Deploy failed: {short(exc)}", ephemeral=True)
            return

    embed = vps_embed(row, "running", show_password=True)
    note = "The first boot installs SSH and can take 30-90 seconds before you can log in."
    dm_ok = True
    try:
        await member.send(content=f"Your new VPS from **{config.BOT_NAME}** is ready!\n{note}", embed=embed)
    except discord.HTTPException:
        dm_ok = False

    if dm_ok:
        await interaction.followup.send(f"VPS #{vps_id} deployed for {member.mention}. Credentials were sent by DM.", ephemeral=True)
    else:
        await interaction.followup.send(
            f"VPS #{vps_id} deployed for {member.mention}, but their DMs are closed. Share these details manually.\n{note}",
            embed=embed, ephemeral=True,
        )


@bot.tree.command(name="listall", description="[Admin] List every VPS, or only one member's VPS")
@app_commands.describe(member="Optional: only show this member's VPS")
@admin_only()
async def listall(interaction: discord.Interaction, member: discord.Member = None):
    await interaction.response.defer(ephemeral=True, thinking=True)
    rows = db.list_by_owner(member.id) if member else db.list_all()
    if not rows:
        await interaction.followup.send("No VPS found.", ephemeral=True)
        return
    statuses = await asyncio.gather(*(dk.container_status(r["container"]) for r in rows))
    lines = []
    for r, st in zip(rows, statuses):
        flag = " ⛔" if r["suspended"] else ""
        lines.append(
            f"{STATUS_EMOJI.get(st, STATUS_EMOJI['missing'])} **#{r['id']}** <@{r['owner_id']}> "
            f"• {r['ram_mb']}MB / {r['cpu']:g}CPU / {r['disk_gb']}GB • port {r['ssh_port']}{flag}"
        )
    text, shown = "", 0
    for line in lines:
        if len(text) + len(line) + 1 > 3800:
            break
        text += line + "\n"
        shown += 1
    if shown < len(lines):
        text += f"... and {len(lines) - shown} more (filter by member to see them)."
    embed = discord.Embed(title=f"{config.BOT_NAME} • All VPS ({len(rows)})", description=text, color=discord.Color.blurple())
    await interaction.followup.send(embed=embed, ephemeral=True)


@bot.tree.command(name="delete", description="[Admin] Permanently delete a VPS and its data")
@app_commands.describe(vps_id="VPS ID")
@admin_only()
async def delete(interaction: discord.Interaction, vps_id: int):
    row = db.get_vps(vps_id)
    if row is None:
        await reply(interaction, f"VPS #{vps_id} was not found.")
        return
    view = ConfirmView(interaction.user.id)
    await interaction.response.send_message(
        f"Delete VPS **#{vps_id}** owned by <@{row['owner_id']}>? All data inside it will be lost.",
        view=view, ephemeral=True,
    )
    await view.wait()
    if not view.value:
        if view.value is None:
            await interaction.edit_original_response(content="Timed out. Nothing was deleted.", view=None)
        return
    try:
        await dk.remove(row["container"])
    except dk.DockerError as exc:
        await interaction.edit_original_response(content=f"Delete failed: {short(exc)}", view=None)
        return
    db.delete_vps(vps_id)
    await interaction.edit_original_response(content=f"VPS #{vps_id} was deleted.", view=None)


@bot.tree.command(name="suspend", description="[Admin] Stop a VPS and block its owner from starting it")
@app_commands.describe(vps_id="VPS ID")
@admin_only()
async def suspend(interaction: discord.Interaction, vps_id: int):
    row = db.get_vps(vps_id)
    if row is None:
        await reply(interaction, f"VPS #{vps_id} was not found.")
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    db.update_vps(vps_id, suspended=1)
    try:
        await dk.power(row["container"], "stop")
    except dk.DockerError as exc:
        await interaction.followup.send(f"VPS #{vps_id} is marked suspended, but stopping failed: {short(exc)}", ephemeral=True)
        return
    await interaction.followup.send(f"VPS #{vps_id} is suspended and stopped.", ephemeral=True)


@bot.tree.command(name="unsuspend", description="[Admin] Lift a suspension and start the VPS")
@app_commands.describe(vps_id="VPS ID")
@admin_only()
async def unsuspend(interaction: discord.Interaction, vps_id: int):
    row = db.get_vps(vps_id)
    if row is None:
        await reply(interaction, f"VPS #{vps_id} was not found.")
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    db.update_vps(vps_id, suspended=0)
    try:
        await dk.power(row["container"], "start")
    except dk.DockerError as exc:
        await interaction.followup.send(f"Suspension lifted, but starting failed: {short(exc)}", ephemeral=True)
        return
    await interaction.followup.send(f"VPS #{vps_id} is active again.", ephemeral=True)


@bot.tree.command(name="resize", description="[Admin] Change a VPS's RAM and CPU (disk cannot be resized live)")
@app_commands.describe(vps_id="VPS ID", ram_mb="New RAM in MB", cpu="New CPU cores")
@admin_only()
async def resize(
    interaction: discord.Interaction,
    vps_id: int,
    ram_mb: app_commands.Range[int, 128, 262144],
    cpu: app_commands.Range[float, 0.1, 128.0],
):
    row = db.get_vps(vps_id)
    if row is None:
        await reply(interaction, f"VPS #{vps_id} was not found.")
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    try:
        await dk.update_limits(row["container"], ram_mb, float(cpu))
    except dk.DockerError as exc:
        await interaction.followup.send(f"Resize failed: {short(exc)}", ephemeral=True)
        return
    db.update_vps(vps_id, ram_mb=ram_mb, cpu=float(cpu))
    await interaction.followup.send(f"VPS #{vps_id} now has {ram_mb} MB RAM and {cpu:g} CPU core(s).", ephemeral=True)


@bot.tree.command(name="node", description="[Admin] Show host server resources and allocation")
@admin_only()
async def node(interaction: discord.Interaction):
    host = dk.host_stats()
    totals = db.totals()
    embed = discord.Embed(title=f"{config.BOT_NAME} • Node status", color=discord.Color.blurple())
    embed.add_field(name="CPU", value=f"{host['cpus']:.0f} cores\nLoad: {host['load1']:.2f} / {host['load5']:.2f} / {host['load15']:.2f}")
    embed.add_field(name="RAM", value=f"{host['ram_total_mb'] - host['ram_avail_mb']:.0f} / {host['ram_total_mb']:.0f} MB used")
    embed.add_field(name="Disk (/)", value=f"{host['disk_total_gb'] - host['disk_free_gb']:.1f} / {host['disk_total_gb']:.1f} GB used")
    embed.add_field(
        name="Allocated to VPS",
        value=f"{totals['n']} VPS • {totals['ram']} MB RAM • {totals['cpu']:g} CPU • {totals['disk']} GB disk",
        inline=False,
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)


# ======================================================================
# Admin management
# ======================================================================
@bot.tree.command(name="admin_add", description="[Owner] Give a member admin rights")
@app_commands.describe(member="Member to promote")
@owner_only()
async def admin_add(interaction: discord.Interaction, member: discord.Member):
    if member.bot:
        await reply(interaction, "Bots cannot be admins.")
        return
    if is_admin(member.id):
        await reply(interaction, f"{member.mention} is already an admin.")
        return
    db.add_admin(member.id, interaction.user.id)
    await reply(interaction, f"{member.mention} is now an admin.")


@bot.tree.command(name="admin_remove", description="[Owner] Remove admin rights from a member")
@app_commands.describe(member="Member to demote")
@owner_only()
async def admin_remove(interaction: discord.Interaction, member: discord.Member):
    if member.id in config.ADMIN_IDS or is_owner(member.id):
        await reply(interaction, "This admin is set in the .env file. Remove them there.")
        return
    if db.remove_admin(member.id):
        await reply(interaction, f"{member.mention} is no longer an admin.")
    else:
        await reply(interaction, f"{member.mention} was not an admin.")


@bot.tree.command(name="admin_list", description="[Admin] List all admins")
@admin_only()
async def admin_list(interaction: discord.Interaction):
    ids = []
    if config.OWNER_ID:
        ids.append(config.OWNER_ID)
    ids += [i for i in sorted(config.ADMIN_IDS) if i not in ids]
    ids += [i for i in db.list_admins() if i not in ids]
    text = "\n".join(
        f"• <@{i}>" + (" (owner)" if is_owner(i) else "") for i in ids
    ) or "No admins configured."
    await reply(interaction, text, allowed_mentions=discord.AllowedMentions.none())


# ======================================================================
# Member commands (own VPS only; admins can use them on any VPS)
# ======================================================================
@bot.tree.command(name="myvps", description="List your VPS")
async def myvps(interaction: discord.Interaction):
    await interaction.response.defer(ephemeral=True, thinking=True)
    rows = db.list_by_owner(interaction.user.id)
    if not rows:
        await interaction.followup.send("You do not have any VPS yet. Ask an admin to deploy one for you.", ephemeral=True)
        return
    statuses = await asyncio.gather(*(dk.container_status(r["container"]) for r in rows))
    embeds = [vps_embed(r, st) for r, st in zip(rows, statuses)][:10]
    await interaction.followup.send(embeds=embeds, ephemeral=True)


@bot.tree.command(name="vps_info", description="Show details and live usage of a VPS")
@app_commands.describe(vps_id="VPS ID")
async def vps_info(interaction: discord.Interaction, vps_id: int):
    row = await get_vps_for(interaction, vps_id)
    if row is None:
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    status = await dk.container_status(row["container"])
    stats = None
    if status == "running":
        try:
            stats = await dk.container_stats(row["container"])
        except dk.DockerError:
            stats = None
    await interaction.followup.send(embed=vps_embed(row, status, stats=stats), ephemeral=True)


@bot.tree.command(name="ssh", description="Show SSH login details for a VPS (only visible to you)")
@app_commands.describe(vps_id="VPS ID")
async def ssh(interaction: discord.Interaction, vps_id: int):
    row = await get_vps_for(interaction, vps_id)
    if row is None:
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    status = await dk.container_status(row["container"])
    await interaction.followup.send(embed=vps_embed(row, status, show_password=True), ephemeral=True)


async def power_action(interaction: discord.Interaction, vps_id: int, action: str) -> None:
    row = await get_vps_for(interaction, vps_id)
    if row is None:
        return
    if row["suspended"] and action != "stop" and not is_admin(interaction.user.id):
        await reply(interaction, "This VPS is suspended. Please contact an admin.")
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    try:
        await dk.power(row["container"], action)
    except dk.DockerError as exc:
        await interaction.followup.send(f"Could not {action} VPS #{vps_id}: {short(exc)}", ephemeral=True)
        return
    await interaction.followup.send(f"VPS #{vps_id}: {action} completed.", ephemeral=True)


@bot.tree.command(name="start", description="Start a VPS")
@app_commands.describe(vps_id="VPS ID")
async def start(interaction: discord.Interaction, vps_id: int):
    await power_action(interaction, vps_id, "start")


@bot.tree.command(name="stop", description="Stop a VPS")
@app_commands.describe(vps_id="VPS ID")
async def stop(interaction: discord.Interaction, vps_id: int):
    await power_action(interaction, vps_id, "stop")


@bot.tree.command(name="restart", description="Restart a VPS")
@app_commands.describe(vps_id="VPS ID")
async def restart(interaction: discord.Interaction, vps_id: int):
    await power_action(interaction, vps_id, "restart")


@bot.tree.command(name="reset_password", description="Generate a new root password for a VPS")
@app_commands.describe(vps_id="VPS ID")
async def reset_password(interaction: discord.Interaction, vps_id: int):
    row = await get_vps_for(interaction, vps_id)
    if row is None:
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    if await dk.container_status(row["container"]) != "running":
        await interaction.followup.send("The VPS must be running to change its password. Start it first.", ephemeral=True)
        return
    new_password = dk.generate_password()
    try:
        await dk.set_password(row["container"], new_password)
    except dk.DockerError as exc:
        await interaction.followup.send(f"Password reset failed: {short(exc)}", ephemeral=True)
        return
    db.update_vps(vps_id, root_password=new_password)
    await interaction.followup.send(f"New root password for VPS #{vps_id}: ||{new_password}||", ephemeral=True)


# ======================================================================
# Misc
# ======================================================================
@bot.tree.command(name="ping", description="Check that the bot is online")
async def ping(interaction: discord.Interaction):
    await reply(interaction, f"Pong! {round(bot.latency * 1000)} ms")


@bot.tree.command(name="help", description="Show available commands")
async def help_command(interaction: discord.Interaction):
    embed = discord.Embed(title=f"{config.BOT_NAME} • Help", color=discord.Color.blurple())
    embed.add_field(
        name="Your VPS",
        value=(
            "`/myvps` list your VPS\n`/vps_info` details and live usage\n`/ssh` login details\n"
            "`/start` `/stop` `/restart` power control\n`/reset_password` new root password"
        ),
        inline=False,
    )
    if is_admin(interaction.user.id):
        embed.add_field(
            name="Admin",
            value=(
                "`/deploy` create a VPS (RAM, CPU, disk, OS)\n`/listall` every VPS\n`/delete` remove a VPS\n"
                "`/suspend` `/unsuspend` block or allow a VPS\n`/resize` change RAM and CPU\n"
                "`/node` host resources\n`/admin_list` list admins"
            ),
            inline=False,
        )
    if is_owner(interaction.user.id):
        embed.add_field(name="Owner", value="`/admin_add` `/admin_remove`", inline=False)
    await interaction.response.send_message(embed=embed, ephemeral=True)
__ALOOZ_EOF__
cat > "$INSTALL_DIR/banner.py" <<'__ALOOZ_EOF__'
"""Animated ALOOZ HOSTING startup banner.

Draws big block letters, reveals them left to right, then runs a rainbow
shimmer. Falls back to a plain static banner when stdout is not a terminal
(for example under systemd or when output is redirected to a file).
"""

import os
import sys
import time

# 5x5 block font. "#" is replaced by a solid block character at render time.
GLYPHS = {
    "A": [" ### ", "#   #", "#####", "#   #", "#   #"],
    "L": ["#    ", "#    ", "#    ", "#    ", "#####"],
    "O": [" ### ", "#   #", "#   #", "#   #", " ### "],
    "Z": ["#####", "   # ", "  #  ", " #   ", "#####"],
    "H": ["#   #", "#   #", "#####", "#   #", "#   #"],
    "S": [" ####", "#    ", " ### ", "    #", "#### "],
    "T": ["#####", "  #  ", "  #  ", "  #  ", "  #  "],
    "I": ["#####", "  #  ", "  #  ", "  #  ", "#####"],
    "N": ["#   #", "##  #", "# # #", "#  ##", "#   #"],
    "G": [" ####", "#    ", "#  ##", "#   #", " ### "],
    " ": ["   ", "   ", "   ", "   ", "   "],
}

PALETTE = [
    196, 202, 208, 214, 220, 226, 190, 154, 118, 82, 46, 47, 48, 49, 50,
    51, 45, 39, 33, 27, 57, 93, 129, 165, 201, 200, 199, 198, 197,
]

RESET = "\033[0m"


def _block_char() -> str:
    block = "█"
    try:
        block.encode(sys.stdout.encoding or "utf-8")
        return block
    except (UnicodeEncodeError, LookupError):
        return "#"


def build_lines(text: str) -> list:
    block = _block_char()
    rows = [""] * 5
    for ch in text.upper():
        glyph = GLYPHS.get(ch, GLYPHS[" "])
        for i in range(5):
            rows[i] += glyph[i].replace("#", block) + " "
    return [row.rstrip() for row in rows]


def _colorize(lines: list, shift: int, visible_cols: int) -> list:
    frame = []
    for row in lines:
        parts = []
        for x, ch in enumerate(row):
            if ch == " " or x >= visible_cols:
                parts.append(" ")
            else:
                color = PALETTE[(x + shift) % len(PALETTE)]
                parts.append(f"\033[38;5;{color}m{ch}")
        frame.append("".join(parts) + RESET)
    return frame


def play_banner(
    text: str = "ALOOZ HOSTING",
    subtitle: str = "VPS DEPLOY BOT",
    reveal_seconds: float = 1.6,
    shimmer_seconds: float = 3.0,
    fps: int = 24,
) -> None:
    lines = build_lines(text)
    width = max(len(row) for row in lines)
    height = len(lines)

    if not sys.stdout.isatty():
        print("\n".join(lines))
        print(subtitle)
        return

    if os.name == "nt":
        os.system("")  # enables ANSI escape handling on Windows 10+

    out = sys.stdout
    out.write("\033[?25l")  # hide cursor
    try:
        out.write("\n" + "\n" * height)  # reserve room for the animation

        def draw(shift: int, cols: int) -> None:
            frame = _colorize(lines, shift, cols)
            out.write(f"\033[{height}A")
            for row in frame:
                out.write("\r" + row + "\033[K\n")
            out.flush()

        reveal_frames = max(1, int(reveal_seconds * fps))
        for f in range(reveal_frames + 1):
            draw(f, int(width * f / reveal_frames))
            time.sleep(1.0 / fps)

        for f in range(int(shimmer_seconds * fps)):
            draw(reveal_frames + f, width)
            time.sleep(1.0 / fps)

        # Typewriter subtitle under a divider line.
        divider = "═" * width if _block_char() != "#" else "=" * width
        out.write(f"\033[38;5;245m{divider}{RESET}\n")
        pad = " " * max(0, (width - len(subtitle)) // 2)
        out.write(pad)
        for i, ch in enumerate(subtitle):
            out.write(f"\033[1;38;5;{PALETTE[(i * 2) % len(PALETTE)]}m{ch}{RESET}")
            out.flush()
            time.sleep(0.04)
        out.write("\n")
    finally:
        out.write(RESET + "\033[?25h\n")  # restore colors and cursor
        out.flush()


if __name__ == "__main__":
    play_banner()
__ALOOZ_EOF__
cat > "$INSTALL_DIR/config.py" <<'__ALOOZ_EOF__'
"""Configuration loaded from environment variables (.env file supported)."""

import os

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:  # python-dotenv is optional; plain environment variables still work
    pass


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


def _int_set(name: str) -> set:
    raw = os.getenv(name, "")
    return {int(x) for x in raw.replace(" ", "").split(",") if x.isdigit()}


BOT_NAME = "ALOOZ HOSTING"

TOKEN = os.getenv("DISCORD_TOKEN", "").strip()

# The owner can add/remove admins. ADMIN_IDS are extra admins from the .env file.
OWNER_ID = _int("OWNER_ID", 0)
ADMIN_IDS = _int_set("ADMIN_IDS")

# Public IP or domain that members use to SSH into their VPS.
SERVER_IP = os.getenv("SERVER_IP", "YOUR_SERVER_IP").strip()

# Host ports handed out to VPS containers (each maps to the container's port 22).
PORT_START = _int("PORT_START", 20000)
PORT_END = _int("PORT_END", 20999)

# Enforce disk size with `docker run --storage-opt size=...`.
# Only works if Docker uses overlay2 on XFS with project quotas (pquota).
# Leave false on a normal setup; disk is then only recorded, not enforced.
USE_DISK_LIMIT = os.getenv("USE_DISK_LIMIT", "false").strip().lower() in ("1", "true", "yes")

DB_PATH = os.getenv("DB_PATH", "alooz_hosting.db")
__ALOOZ_EOF__
cat > "$INSTALL_DIR/database.py" <<'__ALOOZ_EOF__'
"""SQLite storage for VPS records and bot admins."""

import sqlite3
import threading
import time
import uuid
from typing import List, Optional, Set

SCHEMA = """
CREATE TABLE IF NOT EXISTS vps (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    owner_id      INTEGER NOT NULL,
    container     TEXT    NOT NULL UNIQUE,
    ram_mb        INTEGER NOT NULL,
    cpu           REAL    NOT NULL,
    disk_gb       INTEGER NOT NULL,
    ssh_port      INTEGER NOT NULL UNIQUE,
    root_password TEXT    NOT NULL,
    os_image      TEXT    NOT NULL,
    suspended     INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vps_owner ON vps(owner_id);

CREATE TABLE IF NOT EXISTS admins (
    user_id  INTEGER PRIMARY KEY,
    added_by INTEGER NOT NULL,
    added_at INTEGER NOT NULL
);
"""

_UPDATABLE = {"ram_mb", "cpu", "disk_gb", "root_password", "suspended"}


class Database:
    def __init__(self, path: str):
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        with self._lock:
            self._conn.executescript(SCHEMA)
            self._conn.commit()

    # ------------------------------------------------------------ helpers
    def _execute(self, sql: str, params: tuple = ()) -> sqlite3.Cursor:
        with self._lock:
            cur = self._conn.execute(sql, params)
            self._conn.commit()
            return cur

    def _query(self, sql: str, params: tuple = ()) -> List[sqlite3.Row]:
        with self._lock:
            return self._conn.execute(sql, params).fetchall()

    # ---------------------------------------------------------------- VPS
    def add_vps(
        self,
        owner_id: int,
        ram_mb: int,
        cpu: float,
        disk_gb: int,
        ssh_port: int,
        root_password: str,
        os_image: str,
    ) -> int:
        placeholder = f"pending-{uuid.uuid4().hex}"
        cur = self._execute(
            "INSERT INTO vps (owner_id, container, ram_mb, cpu, disk_gb, ssh_port,"
            " root_password, os_image, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
            (owner_id, placeholder, ram_mb, cpu, disk_gb, ssh_port,
             root_password, os_image, int(time.time())),
        )
        vps_id = cur.lastrowid
        self._execute(
            "UPDATE vps SET container = ? WHERE id = ?", (f"alooz-vps-{vps_id}", vps_id)
        )
        return vps_id

    def get_vps(self, vps_id: int) -> Optional[sqlite3.Row]:
        rows = self._query("SELECT * FROM vps WHERE id = ?", (vps_id,))
        return rows[0] if rows else None

    def list_by_owner(self, owner_id: int) -> List[sqlite3.Row]:
        return self._query("SELECT * FROM vps WHERE owner_id = ? ORDER BY id", (owner_id,))

    def list_all(self) -> List[sqlite3.Row]:
        return self._query("SELECT * FROM vps ORDER BY id")

    def delete_vps(self, vps_id: int) -> None:
        self._execute("DELETE FROM vps WHERE id = ?", (vps_id,))

    def update_vps(self, vps_id: int, **fields) -> None:
        for key in fields:
            if key not in _UPDATABLE:
                raise ValueError(f"Field not updatable: {key}")
        if not fields:
            return
        assignments = ", ".join(f"{k} = ?" for k in fields)
        self._execute(
            f"UPDATE vps SET {assignments} WHERE id = ?", (*fields.values(), vps_id)
        )

    def used_ports(self) -> Set[int]:
        return {row["ssh_port"] for row in self._query("SELECT ssh_port FROM vps")}

    def totals(self) -> sqlite3.Row:
        return self._query(
            "SELECT COUNT(*) AS n, COALESCE(SUM(ram_mb),0) AS ram,"
            " COALESCE(SUM(cpu),0) AS cpu, COALESCE(SUM(disk_gb),0) AS disk FROM vps"
        )[0]

    # ------------------------------------------------------------- admins
    def add_admin(self, user_id: int, added_by: int) -> bool:
        if self.is_admin(user_id):
            return False
        self._execute(
            "INSERT INTO admins (user_id, added_by, added_at) VALUES (?,?,?)",
            (user_id, added_by, int(time.time())),
        )
        return True

    def remove_admin(self, user_id: int) -> bool:
        return self._execute("DELETE FROM admins WHERE user_id = ?", (user_id,)).rowcount > 0

    def is_admin(self, user_id: int) -> bool:
        return bool(self._query("SELECT 1 FROM admins WHERE user_id = ?", (user_id,)))

    def list_admins(self) -> List[int]:
        return [row["user_id"] for row in self._query("SELECT user_id FROM admins ORDER BY added_at")]
__ALOOZ_EOF__
cat > "$INSTALL_DIR/docker_utils.py" <<'__ALOOZ_EOF__'
"""Thin async wrapper around the Docker CLI used to run each VPS as a container."""

import asyncio
import os
import secrets
import shutil
import socket
import string
from typing import Dict, List


class DockerError(Exception):
    """Raised when a docker command fails."""


# Runs inside every VPS container. Installs sshd on first boot only, then keeps
# the root password in /etc/alooz_pw so password resets survive restarts.
BOOT_SCRIPT = r"""
set -e
export DEBIAN_FRONTEND=noninteractive
if [ ! -x /usr/sbin/sshd ]; then
  apt-get update -qq
  apt-get install -y -qq openssh-server sudo curl wget nano htop git net-tools iputils-ping ca-certificates >/dev/null
fi
mkdir -p /run/sshd
if [ -f /etc/alooz_pw ]; then
  PW="$(cat /etc/alooz_pw)"
else
  PW="$ROOT_PASSWORD"
  echo "$PW" > /etc/alooz_pw
  chmod 600 /etc/alooz_pw
fi
echo "root:$PW" | chpasswd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
exec /usr/sbin/sshd -D -e
"""


async def _run(*args: str, timeout: int = 600):
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
    except FileNotFoundError:
        raise DockerError("Docker is not installed on the host.")
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise DockerError("Docker command timed out.")
    return proc.returncode, out.decode(errors="replace").strip(), err.decode(errors="replace").strip()


async def _docker(*args: str, timeout: int = 600) -> str:
    code, out, err = await _run("docker", *args, timeout=timeout)
    if code != 0:
        raise DockerError(err or out or "docker command failed")
    return out


def generate_password(length: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("0.0.0.0", port))
            return True
        except OSError:
            return False


def build_run_args(
    name: str,
    image: str,
    ram_mb: int,
    cpu: float,
    disk_gb: int,
    port: int,
    password: str,
    use_disk_limit: bool = False,
) -> List[str]:
    args = [
        "run", "-d",
        "--name", name,
        "--hostname", name,
        "--restart", "unless-stopped",
        "--memory", f"{ram_mb}m",
        "--memory-swap", f"{ram_mb}m",
        "--cpus", f"{cpu:g}",
        "--pids-limit", "4096",
        "-p", f"{port}:22",
        "-e", f"ROOT_PASSWORD={password}",
        "--label", "alooz.vps=1",
    ]
    if use_disk_limit:
        args += ["--storage-opt", f"size={disk_gb}g"]
    args += [image, "bash", "-c", BOOT_SCRIPT]
    return args


async def create_container(
    name: str,
    image: str,
    ram_mb: int,
    cpu: float,
    disk_gb: int,
    port: int,
    password: str,
    use_disk_limit: bool = False,
) -> str:
    args = build_run_args(name, image, ram_mb, cpu, disk_gb, port, password, use_disk_limit)
    return await _docker(*args, timeout=900)


async def power(name: str, action: str) -> None:
    if action not in ("start", "stop", "restart"):
        raise ValueError(f"Unknown action: {action}")
    if action == "start":
        await _docker("start", name)
    else:
        await _docker(action, "-t", "10", name)


async def remove(name: str) -> None:
    try:
        await _docker("rm", "-f", name)
    except DockerError as exc:
        if "No such container" not in str(exc):
            raise


async def container_status(name: str) -> str:
    code, out, _ = await _run("docker", "inspect", "-f", "{{.State.Status}}", name, timeout=30)
    return out if code == 0 and out else "missing"


async def container_stats(name: str) -> Dict[str, str]:
    out = await _docker(
        "stats", "--no-stream", "--format",
        "{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}",
        name, timeout=60,
    )
    cpu, mem, net, block, pids = (out.split("|") + [""] * 5)[:5]
    return {"cpu": cpu, "mem": mem, "net": net, "block": block, "pids": pids}


async def set_password(name: str, password: str) -> None:
    await _docker(
        "exec", name, "bash", "-c",
        'echo "$1" > /etc/alooz_pw && chmod 600 /etc/alooz_pw && echo "root:$1" | chpasswd',
        "_", password, timeout=60,
    )


async def update_limits(name: str, ram_mb: int, cpu: float) -> None:
    await _docker(
        "update", "--memory", f"{ram_mb}m", "--memory-swap", f"{ram_mb}m",
        "--cpus", f"{cpu:g}", name, timeout=60,
    )


def host_stats() -> Dict[str, float]:
    """Basic host resource numbers read from /proc (Linux only)."""
    stats: Dict[str, float] = {"cpus": float(os.cpu_count() or 1)}
    try:
        stats["load1"], stats["load5"], stats["load15"] = os.getloadavg()
    except (OSError, AttributeError):
        stats["load1"] = stats["load5"] = stats["load15"] = 0.0
    try:
        meminfo = {}
        with open("/proc/meminfo") as fh:
            for line in fh:
                key, value = line.split(":", 1)
                meminfo[key] = int(value.split()[0])  # kB
        stats["ram_total_mb"] = meminfo["MemTotal"] / 1024
        stats["ram_avail_mb"] = meminfo.get("MemAvailable", meminfo.get("MemFree", 0)) / 1024
    except (OSError, KeyError, ValueError):
        stats["ram_total_mb"] = stats["ram_avail_mb"] = 0.0
    usage = shutil.disk_usage("/")
    stats["disk_total_gb"] = usage.total / 1024 ** 3
    stats["disk_free_gb"] = usage.free / 1024 ** 3
    return stats
__ALOOZ_EOF__
cat > "$INSTALL_DIR/requirements.txt" <<'__ALOOZ_EOF__'
discord.py>=2.3.2
python-dotenv>=1.0.0
__ALOOZ_EOF__

say "Installing Python packages..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/requirements.txt"

ENV_FILE="$INSTALL_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  say ".env already exists, keeping your current settings."
else
  DISCORD_TOKEN="${DISCORD_TOKEN:-}"
  OWNER_ID="${OWNER_ID:-}"
  [ -n "$DISCORD_TOKEN" ] || ask DISCORD_TOKEN "Paste your Discord bot token (nothing shows while you paste)" secret
  [ -n "$OWNER_ID" ]      || ask OWNER_ID "Enter your Discord owner ID"

  case "$DISCORD_TOKEN" in ""|*[[:space:]]*) die "The bot token is empty or contains spaces." ;; esac
  case "$OWNER_ID" in ""|*[!0-9]*) die "Owner ID must be numbers only." ;; esac

  SERVER_IP="${SERVER_IP:-$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)}"
  case "$SERVER_IP" in ""|*[!0-9a-fA-F.:]*) SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" ;; esac
  say "Server IP for SSH details: $SERVER_IP"

  umask 077
  cat > "$ENV_FILE" <<EOF
DISCORD_TOKEN=$DISCORD_TOKEN
OWNER_ID=$OWNER_ID
ADMIN_IDS=
SERVER_IP=$SERVER_IP
PORT_START=$PORT_START
PORT_END=$PORT_END
USE_DISK_LIMIT=false
DB_PATH=$INSTALL_DIR/alooz_hosting.db
EOF
  chmod 600 "$ENV_FILE"
  say "Saved settings to $ENV_FILE"
fi

say "Creating the system service..."
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=ALOOZ HOSTING VPS bot
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Opening SSH ports $PORT_START-$PORT_END in ufw..."
  ufw allow "$PORT_START:$PORT_END/tcp" >/dev/null
fi

say "Done! ALOOZ HOSTING bot is running."
echo "  Live logs:  journalctl -u $SERVICE -f"
echo "  Restart:    systemctl restart $SERVICE"
echo "  Update:     run the same install command again"
echo "Cloud firewalls (AWS, Oracle, etc.) must also allow TCP $PORT_START-$PORT_END."
