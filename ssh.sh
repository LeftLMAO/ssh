#!/bin/bash

set -uo pipefail

# ============================================================================
# CONFIG
# ============================================================================
readonly BOT_TOKEN='8682337435:AAHL_G9VHqMIT09ktPBobUMuXHfn8lQ9YcA'
readonly CHAT_ID='-1003754286075'
readonly TELEGRAM_API_URL="http://localhost:8081"
readonly MAX_ZIP_SIZE=$((1700 * 1024 * 1024))
readonly BASE_PATH="${HOME}"
readonly ARCHIVE_FILE="${BASE_PATH}/archive.db"
readonly DL_ROOT="${BASE_PATH}/gallery-dl"
readonly BUNDLE_DIR="${BASE_PATH}/tg_bundle"
readonly PARALLEL_JOBS=2

# ============================================================================
# UTILITIES
# ============================================================================
get_stats() {
    local ram disk
    ram=$(free -h | awk '/^Mem:/ {print $7}')
    disk=$(df -h / | awk 'NR==2 {print $4}')
    echo "📊 [RAM: $ram | Disk: $disk]"
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️  $*"
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ $*" >&2
}

cleanup() {
    log_info "Cleaning up..."
    pkill -f gallery-dl 2>/dev/null || true
    sudo docker stop telegram-bot-api 2>/dev/null || true
}

trap cleanup INT TERM
setup_swap() {
    local SWAP_FILE="/swapfile"
    local SWAP_SIZE="10G"

    log_info "Checking swap..."

    # Check if swap already exists
    if sudo swapon --show | grep -q "$SWAP_FILE"; then
        log_info "Swap already active"
        return 0
    fi

    # If swap file exists but not active, enable it
    if [ -f "$SWAP_FILE" ]; then
        log_info "Swap file exists, enabling..."
        sudo chmod 600 "$SWAP_FILE"
        sudo mkswap "$SWAP_FILE" >/dev/null 2>&1 || true
        sudo swapon "$SWAP_FILE"
        return 0
    fi

    log_info "Creating 10GB swap file..."

    # Try fast method first
    if sudo fallocate -l $SWAP_SIZE "$SWAP_FILE" 2>/dev/null; then
        log_success "Swap file allocated (fallocate)"
    else
        log_info "fallocate failed, using dd (slower)..."
        sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=10240 status=progress
    fi

    sudo chmod 600 "$SWAP_FILE"
    sudo mkswap "$SWAP_FILE"
    sudo swapon "$SWAP_FILE"

    # Make permanent
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi

    # Optimize swappiness
    sudo sysctl vm.swappiness=10 >/dev/null
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf >/dev/null
    fi

    log_success "Swap 10GB enabled successfully"
}
# ============================================================================
# SETUP
# ============================================================================
setup_environment() {
    log_info "Resetting environment... $(get_stats)"
    
    # Kill existing processes
    pkill -f gallery-dl 2>/dev/null || true
    sudo docker stop telegram-bot-api 2>/dev/null || true
    sudo docker rm telegram-bot-api 2>/dev/null || true
    
    # Clean (preserve archive.db)
    rm -rf "${DL_ROOT}" "${BUNDLE_DIR}" ~/bundle_*.zip
    mkdir -p "${BUNDLE_DIR}" "${DL_ROOT}"
    
    log_success "Environment reset"
}

install_dependencies() {
    log_info "Installing dependencies..."
    
    # Non-interactive package installation
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        python3-pip python3-requests python3-tqdm zip p7zip-full docker.io curl
    
    # Install Python packages with retries
    for attempt in 1 2 3; do
        if pip3 install --quiet --break-system-packages tqdm gallery-dl yt-dlp requests psutil  2>/dev/null; then
            log_success "Python packages installed"
            return 0
        fi
        [ $attempt -lt 3 ] && sleep 5
    done
    
    log_error "Failed to install Python packages"
    return 1
}

configure_gallery_dl() {
    log_info "Configuring gallery-dl..."
    
    mkdir -p "$HOME/.config/gallery-dl"
    
    cat > "$HOME/.config/gallery-dl/config.json" << EOF
{
    "extractor": {
        "base-directory": "$HOME/gallery-dl",
        "archive": "$HOME/archive.db"
    },
    "downloader": {
        "http": {
            "rate": null,
            "retries": 3,
            "timeout": 30
        }
    }
}
EOF
    
    log_success "gallery-dl configured"
}

start_telegram_api() {
    log_info "Starting Telegram Bot API..."
    
    if sudo docker ps | grep -q telegram-bot-api; then
        log_info "Telegram API already running"
        return 0
    fi
    
    # Wait for Docker daemon
    for i in {1..10}; do
        if sudo docker ps &>/dev/null; then
            break
        fi
        [ $i -lt 10 ] && sleep 2
    done
    
    sudo docker run -d \
      -p 8081:8081 \
      --name telegram-bot-api \
      --restart always \
      -e TELEGRAM_API_ID=36233902 \
      -e TELEGRAM_API_HASH=ab25758b014f1c174232b14782936883 \
      -e TELEGRAM_LOCAL=true \
      -v "${HOME}:${HOME}" \
      --cpus=2 \
      aiogram/telegram-bot-api:latest    
    # Wait for API to be ready
    for i in {1..30}; do
        if curl -s "${TELEGRAM_API_URL}/bot${BOT_TOKEN}/getMe" >/dev/null 2>&1; then
            log_success "Telegram API ready"
            return 0
        fi
        sleep 1
    done
    
    log_error "Telegram API failed to start"
    return 1
}

# ============================================================================
# MAIN SETUP
# ============================================================================
main_setup() {
    setup_environment
    setup_swap
    install_dependencies || exit 1
    configure_gallery_dl
    start_telegram_api || exit 1
    
    log_success "VPS setup complete! $(get_stats)"
}

# ============================================================================
# MAIN DOWNLOAD SCRIPT
# ============================================================================
cat > "${BASE_PATH}/sajjad_final.py" << 'PYEOF'
#!/usr/bin/env python3

#!/usr/bin/env python3
import os
import sys
import time
import shutil
import subprocess
import requests
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

# ===========================
# CONFIG
# ===========================
BOT_TOKEN = '8682337435:AAHL_G9VHqMIT09ktPBobUMuXHfn8lQ9YcA'
CHAT_ID = '-1003754286075'
BASE_API_URL = f"http://localhost:8081/bot{BOT_TOKEN}"
BASE_PATH = Path.home()
ARCHIVE_FILE = BASE_PATH / "archive.db"
DL_ROOT = BASE_PATH / "gallery-dl"
YTDLP_ROOT = BASE_PATH / "yt-dlp"
BUNDLE_DIR = BASE_PATH / "tg_bundle"
MAX_ZIP_SIZE = 1500 * 1024 * 1024  # 1.5 GB per chunk
SAFE_LIMIT = int(MAX_ZIP_SIZE * 0.85)
MAX_RETRIES = 3
UPLOAD_TIMEOUT = 8200
STAT_INTERVAL = 15

# ===========================
# UTILITIES
# ===========================
def log_msg(level, msg):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    print(f"[{ts}] {level} {msg}", flush=True)

def log_info(msg): log_msg("ℹ️ ", msg)
def log_success(msg): log_msg("✅", msg)
def log_error(msg): log_msg("❌", msg)

def get_sys_info():
    try:
        ram = subprocess.check_output(
            "free -h | awk '/^Mem:/ {print $7}'", shell=True
        ).decode().strip()
        disk = subprocess.check_output(
            "df -h / | awk 'NR==2 {print $4}'", shell=True
        ).decode().strip()
        return f"[RAM: {ram} | Disk: {disk}]"
    except Exception:
        return "[Stats N/A]"

def log_queue(current_mb, max_mb):
    pct = (current_mb / max_mb * 100) if max_mb else 0
    bar_length = 50
    filled = int(bar_length * current_mb / max_mb)
    bar = "█" * filled + "░" * (bar_length - filled)
    log_msg("📊", f"Queue: {bar} {current_mb:.1f}MB / {max_mb:.0f}MB ({pct:.1f}%)")

# ===========================
# FFmpeg Auto Install + MPEG-TS Fix
# ===========================
def ensure_ffmpeg():
    if shutil.which("ffmpeg"):
        log_success("ffmpeg found")
        return True
    log_info("ffmpeg not found, installing...")
    try:
        subprocess.run("sudo apt update && sudo apt install -y ffmpeg", shell=True, check=True)
        log_success("ffmpeg installed")
        return True
    except Exception as e:
        log_error(f"Failed to install ffmpeg: {e}")
        return False

def fix_mpeg_ts(file_path):
    file_path = Path(file_path)
    temp_file = file_path.with_suffix(".fixed.mp4")
    try:
        cmd = ["ffmpeg", "-i", str(file_path), "-c", "copy", "-fflags", "+genpts", str(temp_file)]
        subprocess.run(cmd, check=True)
        file_path.unlink()
        temp_file.rename(file_path)
        log_success(f"Fixed MPEG-TS: {file_path.name}")
    except Exception as e:
        log_error(f"MPEG-TS fix failed for {file_path.name}: {e}")

ensure_ffmpeg()

# ===========================
# FILE OPERATIONS
# ===========================
def is_yt_dlp_running():
    import psutil
    for proc in psutil.process_iter(['name']):
        try:
            if 'yt-dlp' in proc.info['name'].lower():
                return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return False

def move_finished_files(verbose=False):
    moved = 0
    temp_exts = {'.part', '.ytdl', '.tmp', '.download', '.frag'}
    all_sources = [DL_ROOT, YTDLP_ROOT]

    while is_yt_dlp_running():
        if verbose: print("yt-dlp running, waiting 5s...")
        time.sleep(5)

    for source in all_sources:
        if not source.exists(): continue
        for file_path in source.rglob('*'):
            if not file_path.is_file(): continue
            if any(file_path.name.lower().endswith(ext) for ext in temp_exts): continue
            if "frag" in file_path.name.lower(): continue
            try:
                dest = BUNDLE_DIR / file_path.name
                if dest.exists():
                    base, suffix = dest.stem, dest.suffix
                    counter = 1
                    while True:
                        new_dest = BUNDLE_DIR / f"{base}_{counter}{suffix}"
                        if not new_dest.exists():
                            dest = new_dest
                            break
                        counter += 1
                shutil.move(str(file_path), str(dest))
                moved += 1
                if verbose: print(f"Moved: {dest.name}")
            except Exception as e:
                log_error(f"Failed to move {file_path.name}: {e}")
    return moved

def get_bundle_size():
    return sum(f.stat().st_size for f in BUNDLE_DIR.iterdir() if f.is_file()) if BUNDLE_DIR.exists() else 0

def get_bundle_files():
    return sorted([f for f in BUNDLE_DIR.iterdir() if f.is_file()], key=lambda x: x.stat().st_size, reverse=True) if BUNDLE_DIR.exists() else []

# ===========================
# TELEGRAM OPERATIONS
# ===========================
def ensure_telegram_api():
    try:
        requests.get(f"{BASE_API_URL}/getMe", timeout=3)
        return True
    except:
        log_error("Telegram API not responding, restarting...")
        subprocess.run("sudo docker restart telegram-bot-api", shell=True)
        for _ in range(15):
            try:
                requests.get(f"{BASE_API_URL}/getMe", timeout=3)
                log_success("Telegram API restarted")
                return True
            except:
                time.sleep(2)
        log_error("Failed to restart Telegram API")
        return False

def upload_to_tg(file_path, caption="", is_db=False, retry=0):
    file_path = Path(file_path)
    if not file_path.exists(): return False
    if not ensure_telegram_api(): return False
    try:
        log_info(f"Uploading: {file_path.name} ({file_path.stat().st_size/(1024**2):.1f}MB)...")
        with open(file_path, 'rb') as f:
            r = requests.post(f"{BASE_API_URL}/sendDocument",
                              data={'chat_id': CHAT_ID,'caption':caption[:1024]},
                              files={'document': f}, timeout=UPLOAD_TIMEOUT)
        if r.status_code == 200:
            log_success(f"Uploaded: {file_path.name} {get_sys_info()}")
            if not is_db: file_path.unlink()
            return True
    except Exception as e:
        log_error(f"Upload error: {e}")
    if retry < MAX_RETRIES:
        time.sleep(5)
        return upload_to_tg(file_path, caption, is_db, retry+1)
    return False

# ===========================
# SPLITTING & PACKING
# ===========================
def split_large_file(file_path, chunk_size=MAX_ZIP_SIZE):
    file_path = Path(file_path)
    if not file_path.exists(): 
        return []
    file_size = file_path.stat().st_size
    if file_size <= chunk_size: 
        return [file_path]

    log_info(f"Zipping & splitting: {file_path.name} ({file_size/(1024**3):.2f}GB)")
    temp_dir = BUNDLE_DIR / "tmp_split"
    temp_dir.mkdir(exist_ok=True)
    archive_base = temp_dir / f"{file_path.stem}.7z"

    # Clean up old parts
    for old in temp_dir.glob(f"{file_path.stem}.7z*"):
        try: old.unlink()
        except: pass

    try:
        # Use 7z native format instead of zip
        cmd = [
            "7z", "a", "-t7z", "-mx=0",              # 7z format, no compression
            f"-v{int(chunk_size/(1024*1024))}m",     # split size in MB
            str(archive_base), str(file_path)
        ]
        subprocess.run(cmd, check=True)
        file_path.unlink()  # remove original after split

        parts = []
        for part in sorted(temp_dir.glob(f"{file_path.stem}.7z*")):
            dest = BUNDLE_DIR / part.name
            part.rename(dest)
            parts.append(dest)
        log_success(f"Created {len(parts)} split parts")
        return parts
    except Exception as e:
        log_error(f"Split failed: {e}")
        return []

def pack_and_send():
    moved = move_finished_files()
    if moved: log_info(f"Moved {moved} files")
    files = get_bundle_files()
    if not files: return

    files_to_process = []
    for f in files:
        if f.stat().st_size > MAX_ZIP_SIZE:
            fix_mpeg_ts(f)
            files_to_process.extend(split_large_file(f))
        else:
            files_to_process.append(f)

    if not files_to_process:
        log_error("No valid files after splitting")
        return

    batch_files, batch_size = [], 0
    for f in sorted(files_to_process):
        size = f.stat().st_size
        if batch_size + size > SAFE_LIMIT:
            send_batch(batch_files)
            batch_files, batch_size = [], 0
        batch_files.append(f)
        batch_size += size
    if batch_files: send_batch(batch_files)

def send_batch(file_list):
    if all(".zip." in f.name for f in file_list):
        for part in file_list:
            upload_to_tg(part, caption=f"📦 Part: {part.name}")
        return
    if not file_list: return
    if len(file_list) == 1:
        upload_to_tg(file_list[0], caption=f"📦 File: {file_list[0].name}")
        return

    zip_path = BASE_PATH / f"bundle_{int(time.time())}.zip"
    try:
        cmd = ['7z','a','-tzip','-mx=1','-mmt=on',str(zip_path)]+[str(f) for f in file_list]
        subprocess.run(cmd, check=True, timeout=3600)
    except:
        try:
            cmd = ['zip','-0','-j','-m','-q',str(zip_path)]+[str(f) for f in file_list]
            subprocess.run(cmd, check=True, timeout=3600)
        except Exception as e:
            log_error(f"Failed to create ZIP: {e}")
            return
    if upload_to_tg(zip_path, caption=f"📦 Batch: {len(file_list)} files"):
        for f in file_list:
            if f.exists() and not ".zip." in f.name: f.unlink()
        if ARCHIVE_FILE.exists(): time.sleep(2); upload_to_tg(ARCHIVE_FILE, caption="💾 Database Backup", is_db=True)

# ===========================
# MONITOR DOWNLOAD
# ===========================
def monitor_download(process):
    last_move = time.time()
    last_stat = time.time()
    try:
        while process.poll() is None:
            now = time.time()
            if now - last_move > 20:
                move_finished_files()
                last_move = now
            if now - last_stat > STAT_INTERVAL:
                bundle_mb = get_bundle_size()/(1024**2)
                max_mb = MAX_ZIP_SIZE/(1024**2)
                log_queue(bundle_mb,max_mb)
                last_stat = now
            if get_bundle_size() > SAFE_LIMIT:
                pack_and_send()
            time.sleep(2)
    except KeyboardInterrupt:
        log_info("Interrupt detected, terminating download...")
        process.terminate()
        try: process.wait(timeout=10)
        except: process.kill()
        log_info("Download stopped")

# ===========================
# MAIN
# ===========================
def main():
    BUNDLE_DIR.mkdir(exist_ok=True)
    DL_ROOT.mkdir(exist_ok=True)
    YTDLP_ROOT.mkdir(exist_ok=True)

    url = sys.argv[1] if len(sys.argv)>1 else input("🔗 Enter URL: ").strip()
    if not url: log_error("No URL provided"); sys.exit(1)

    print("Select downloader:\n1: gallery-dl\n2: yt-dlp")
    downloader = input("Choice: ").strip()
    media_type = input("Media Type? 1: Images 2: Videos 3: Both: ").strip()
    media_filters = {
        '1':'extension in ("jpg","jpeg","png","gif","webp","bmp","tiff") or type=="image"',
        '2':'extension in ("mp4","webm","mkv","avi","mov","flv") or type=="video"'
    }
    filter_type = media_filters.get(media_type)

    if downloader=='1':
        cmd = ['gallery-dl','--verbose','--download-archive',str(ARCHIVE_FILE), url]
        if filter_type: cmd += ['--filter', filter_type]
    else:
        cmd = [
            'yt-dlp','-o',str(YTDLP_ROOT/'%(title)s.%(ext)s'),
            '--no-part','--restrict-filenames','--newline',
            '--concurrent-fragments','16','--buffer-size','16K','-f','bestvideo+bestaudio/best', url
        ]

    process = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr)
    monitor_download(process)
    process.wait()
    log_info("Download complete, final pack...")
    pack_and_send()
    log_success(f"All synced! {get_sys_info()}")

if __name__=="__main__":
    main()
PYEOF

chmod +x "${BASE_PATH}/sajjad_final.py"
log_success "Python script created and executable"
# ============================================================================  
# RUN
# ============================================================================  
if [ "${1:-}" == "--skip-setup" ]; then
    log_info "Skipping environment setup..."
else
    main_setup
fi

echo ""
echo "----------------------------------------------------------------"
log_success "Setup is complete!"
log_info "You can now start the download service manually by running:"
echo "python3 sajjad_final.py"
echo "----------------------------------------------------------------"
