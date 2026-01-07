#!/bin/bash
set -e

# xm Installer
# Linked Memory for LLM Agents
#
# Usage:
#   curl -fsSL https://files.anuna.io/xm/latest/install.sh | bash
#
# Environment variables:
#   VERSION       - Version to install (default: latest)
#   INSTALL_DIR   - Binary install directory (default: ~/.local/bin)
#   SKIP_PREREQ   - Set to 1 to skip prerequisite checks

TOOL_NAME="xm"
VERSION="${VERSION:-latest}"
BASE_URL="https://files.anuna.io/xm"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
LIB_DIR="${INSTALL_DIR%/bin}/lib"
SHARE_DIR="${INSTALL_DIR%/bin}/share"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

detect_platform() {
  local detected_os detected_arch

  detected_os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  detected_arch="$(uname -m 2>/dev/null)"

  if [[ -z "$detected_os" ]]; then
    error "Could not detect operating system (uname -s failed)"
  fi

  if [[ -z "$detected_arch" ]]; then
    error "Could not detect architecture (uname -m failed)"
  fi

  case "$detected_os" in
    linux*)  OS="linux" ;;
    darwin*) OS="macos" ;;
    msys*|mingw*|cygwin*) error "Windows is not supported. Use WSL instead." ;;
    *)       error "Unsupported OS: $detected_os" ;;
  esac

  case "$detected_arch" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *)             error "Unsupported architecture: $detected_arch" ;;
  esac

  PLATFORM="${OS}-${ARCH}"

  if [[ -z "$OS" ]] || [[ -z "$ARCH" ]] || [[ -z "$PLATFORM" ]]; then
    error "Platform detection failed: OS=$OS, ARCH=$ARCH, PLATFORM=$PLATFORM"
  fi

  info "Detected platform: $PLATFORM"

  # Warn about macOS builds
  if [[ "$OS" == "macos" ]]; then
    warn "Pre-built macOS binaries may not be available."
    warn "If download fails, build from source:"
    echo "  git clone https://codeberg.org/anuna/meld && cd meld/xm && make install"
    echo ""
  fi
}

check_prerequisites() {
  if [[ "${SKIP_PREREQ:-0}" == "1" ]]; then
    info "Skipping prerequisite checks"
    return
  fi

  step "Checking prerequisites..."

  # Check for Guile
  if ! command -v guile >/dev/null 2>&1; then
    error "Guile 3.0+ is required but not found.

Install Guile:
  # Debian/Ubuntu
  sudo apt install guile-3.0

  # Fedora
  sudo dnf install guile30

  # Arch Linux
  sudo pacman -S guile

  # macOS (Homebrew)
  brew install guile

  # Guix
  guix install guile"
  fi

  # Check Guile version
  GUILE_VERSION=$(guile --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  GUILE_MAJOR=$(echo "$GUILE_VERSION" | cut -d. -f1)
  if [[ "$GUILE_MAJOR" -lt 3 ]]; then
    error "Guile 3.0+ required, found $GUILE_VERSION"
  fi
  info "Found Guile $GUILE_VERSION"

  # Check for Goblins (optional)
  if guile -c "(use-modules (goblins))" 2>/dev/null; then
    info "Found Goblins"
  else
    warn "Goblins not found (optional, needed for OCapN networking)"
    echo "  Install with Guix: guix install guile-goblins"
    echo ""
  fi
}

get_version() {
  if [[ "$VERSION" == "latest" ]]; then
    step "Fetching latest version..."
    VERSION=$(curl -fsSL "$BASE_URL/latest/version.json" 2>/dev/null | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    if [[ -z "$VERSION" ]]; then
      error "Could not determine latest version. Specify VERSION=x.y.z"
    fi
    info "Latest version: v$VERSION"
  fi
}

install_binary() {
  step "Installing $TOOL_NAME v$VERSION for $PLATFORM..."

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  # Construct download URL
  ARCHIVE_NAME="xm-${PLATFORM}.tar.gz"
  DOWNLOAD_URL="$BASE_URL/v$VERSION/$ARCHIVE_NAME"
  ARCHIVE_FILE="$TMP_DIR/$ARCHIVE_NAME"

  info "Downloading from: $DOWNLOAD_URL"

  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE_FILE"; then
      error "Download failed. Pre-built binary may not exist for $PLATFORM.

Build from source instead:
  # Install Rust if needed
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

  # Clone and build
  git clone https://codeberg.org/anuna/meld
  cd meld/xm
  make build
  make install PREFIX=~/.local"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -q "$DOWNLOAD_URL" -O "$ARCHIVE_FILE"; then
      error "Download failed."
    fi
  else
    error "curl or wget is required"
  fi

  # Verify download
  if [[ ! -f "$ARCHIVE_FILE" ]] || [[ ! -s "$ARCHIVE_FILE" ]]; then
    error "Downloaded file is empty or missing"
  fi

  # Extract archive
  info "Extracting archive..."
  tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR"

  # Create directories
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$LIB_DIR"
  mkdir -p "$SHARE_DIR/guile/site/3.0"

  # Install library
  if [[ -f "$TMP_DIR/xm-dist/lib/libxm_ffi.so" ]]; then
    cp "$TMP_DIR/xm-dist/lib/libxm_ffi.so" "$LIB_DIR/"
    info "Library installed to: $LIB_DIR/libxm_ffi.so"
  elif [[ -f "$TMP_DIR/xm-dist/lib/libxm_ffi.dylib" ]]; then
    cp "$TMP_DIR/xm-dist/lib/libxm_ffi.dylib" "$LIB_DIR/"
    info "Library installed to: $LIB_DIR/libxm_ffi.dylib"
  else
    error "Library not found in archive"
  fi

  # Install Guile modules
  if [[ -d "$TMP_DIR/xm-dist/share/guile/site/3.0/xm" ]]; then
    cp -r "$TMP_DIR/xm-dist/share/guile/site/3.0/xm" "$SHARE_DIR/guile/site/3.0/"
    info "Guile modules installed to: $SHARE_DIR/guile/site/3.0/xm"
  else
    error "Guile modules not found in archive"
  fi

  # Install binary wrapper
  if [[ -f "$TMP_DIR/xm-dist/bin/xm" ]]; then
    cp "$TMP_DIR/xm-dist/bin/xm" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/xm"
    info "Binary installed to: $INSTALL_DIR/xm"
  else
    error "Binary not found in archive"
  fi

  # Check if install directory is in PATH
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    warn "$INSTALL_DIR is not in your PATH"
    echo ""
    echo "Add it to your shell profile:"
    if [[ -f "$HOME/.zshrc" ]]; then
      echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
      echo "  source ~/.zshrc"
    else
      echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
      echo "  source ~/.bashrc"
    fi
  fi
}

setup_environment() {
  step "Environment configuration..."
  echo ""
  echo "Add these to your shell profile (~/.bashrc or ~/.zshrc):"
  echo ""
  echo "  # xm environment"
  echo "  export GUILE_LOAD_PATH=\"$SHARE_DIR/guile/site/3.0:\$GUILE_LOAD_PATH\""
  echo "  export XM_LIB_PATH=\"$LIB_DIR\""
  echo ""

  # Optionally create a setup script
  SETUP_SCRIPT="$LIB_DIR/xm-env.sh"
  mkdir -p "$LIB_DIR"
  cat > "$SETUP_SCRIPT" << EOF
# xm environment setup
# Source this file: . $SETUP_SCRIPT
export GUILE_LOAD_PATH="$SHARE_DIR/guile/site/3.0:\$GUILE_LOAD_PATH"
export XM_LIB_PATH="$LIB_DIR"
export PATH="$INSTALL_DIR:\$PATH"
EOF
  info "Environment script created: $SETUP_SCRIPT"
  echo "  Quick setup: source $SETUP_SCRIPT"
}

print_instructions() {
  echo ""
  echo "=========================================="
  echo "  Installation Complete!"
  echo "=========================================="
  echo ""
  echo "Quick Start:"
  echo ""
  echo "  # Source environment (or add to shell profile)"
  echo "  source $LIB_DIR/xm-env.sh"
  echo ""
  echo "  # Create a memory node"
  echo "  xm node create --type entity --title \"My First Note\""
  echo ""
  echo "  # Query all nodes"
  echo "  xm query nodes"
  echo ""
  echo "  # Link nodes together"
  echo "  xm link create <source-id> <target-id> --predicate \"relatedTo\""
  echo ""
  echo "  # Run SPARQL queries"
  echo "  xm query sparql \"SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 10\""
  echo ""
  echo "  # Show all commands"
  echo "  xm --help"
  echo ""
  echo "Documentation: https://codeberg.org/anuna/meld"
  echo "Downloads: https://files.anuna.io/xm"
  echo ""
}

print_usage() {
  echo ""
  echo "xm Installer - Linked Memory for LLM Agents"
  echo ""
  echo "Usage:"
  echo "  curl -fsSL https://files.anuna.io/xm/latest/install.sh | bash"
  echo ""
  echo "Environment variables:"
  echo "  VERSION     - Version to install (default: latest)"
  echo "  INSTALL_DIR - Install directory (default: ~/.local/bin)"
  echo "  SKIP_PREREQ - Set to 1 to skip prerequisite checks"
  echo ""
  echo "Examples:"
  echo "  # Install latest version"
  echo "  curl -fsSL https://files.anuna.io/xm/latest/install.sh | bash"
  echo ""
  echo "  # Install specific version"
  echo "  VERSION=0.1.0 curl -fsSL https://files.anuna.io/xm/latest/install.sh | bash"
  echo ""
  echo "  # Install to custom directory"
  echo "  INSTALL_DIR=/usr/local/bin curl -fsSL ... | bash"
  echo ""
}

main() {
  echo ""
  echo "=========================================="
  echo "  xm Installer"
  echo "  Linked Memory for LLM Agents"
  echo "=========================================="
  echo ""

  detect_platform
  check_prerequisites
  get_version
  install_binary
  setup_environment
  print_instructions
}

# Handle --help
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
  print_usage
  exit 0
fi

main "$@"
