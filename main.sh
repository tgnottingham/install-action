#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

x() {
    local cmd="$1"
    shift
    (
        set -x
        "${cmd}" "$@"
    )
}
retry() {
    for i in {1..5}; do
        if "$@"; then
            return 0
        else
            sleep "${i}"
        fi
    done
    "$@"
}
bail() {
    echo "::error::$*"
    exit 1
}
warn() {
    echo "::warning::$*"
}
info() {
    echo "info: $*"
}
download() {
    local url="$1"
    local bin_dir="$2"
    local bin="$3"
    if [[ "${bin_dir}" == "/usr/"* ]]; then
        if [[ ! -d "${bin_dir}" ]]; then
            bin_dir="${HOME}/.install-action/bin"
            if [[ ! -d "${bin_dir}" ]]; then
                mkdir -p "${bin_dir}"
                echo "${bin_dir}" >>"${GITHUB_PATH}"
                export PATH="${PATH}:${bin_dir}"
            fi
        fi
    fi
    local tar_args=()
    case "${url}" in
        *.tar.gz | *.tgz) tar_args+=("xzf") ;;
        *.tar.bz2 | *.tbz2)
            tar_args+=("xjf")
            if ! type -P bzip2 &>/dev/null; then
                case "${base_distro}" in
                    debian | alpine | fedora) sys_install bzip2 ;;
                esac
            fi
            ;;
        *.tar.xz | *.txz)
            tar_args+=("xJf")
            if ! type -P xz &>/dev/null; then
                case "${base_distro}" in
                    debian) sys_install xz-utils ;;
                    alpine | fedora) sys_install xz ;;
                esac
            fi
            ;;
        *.zip)
            if ! type -P unzip &>/dev/null; then
                case "${base_distro}" in
                    debian | alpine | fedora) sys_install unzip ;;
                esac
            fi
            mkdir -p .install-action-tmp
            (
                cd .install-action-tmp
                info "downloading ${url}"
                retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 "${url}" -o tmp.zip
                unzip tmp.zip
                mv "${bin}" "${bin_dir}/"
            )
            rm -rf .install-action-tmp
            return 0
            ;;
        *) bail "unrecognized archive format '${url}' for ${tool}" ;;
    esac
    tar_args+=("-")
    local components
    components=$(tr <<<"${bin}" -cd '/' | wc -c)
    if [[ "${components}" != "0" ]]; then
        tar_args+=(--strip-components "${components}")
    fi
    info "downloading ${url}"
    retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 "${url}" \
        | tar "${tar_args[@]}" -C "${bin_dir}" "${bin}"
}
install_cargo_binstall() {
    # https://github.com/cargo-bins/cargo-binstall/releases
    local binstall_version="0.18.1"
    local install_binstall='1'
    if [[ -f "${cargo_bin}/cargo-binstall${exe}" ]]; then
        if [[ "$(cargo binstall -V)" == "cargo-binstall ${binstall_version}" ]]; then
            info "cargo-binstall already installed on in ${cargo_bin}/cargo-binstall${exe}"
            install_binstall=''
        else
            info "cargo-binstall already installed on in ${cargo_bin}/cargo-binstall${exe}, but is not compatible version with install-action, upgrading"
            rm "${cargo_bin}/cargo-binstall${exe}"
        fi
    fi

    if [[ -n "${install_binstall}" ]]; then
        info "installing cargo-binstall"

        base_url="https://github.com/cargo-bins/cargo-binstall/releases/download/v${binstall_version}/cargo-binstall"
        case "${OSTYPE}" in
            linux*) url="${base_url}-${host_arch}-unknown-linux-musl.tgz" ;;
            darwin*) url="${base_url}-${host_arch}-apple-darwin.zip" ;;
            cygwin* | msys*) url="${base_url}-x86_64-pc-windows-msvc.zip" ;;
            *) bail "unsupported OSTYPE '${OSTYPE}' for cargo-binstall" ;;
        esac

        download "${url}" "${cargo_bin}" "cargo-binstall${exe}"
        info "cargo-binstall installed at $(type -P "cargo-binstall${exe}")"
        x cargo binstall -V
    fi
}
cargo_binstall() {
    local tool="$1"
    local version="$2"

    info "install-action does not support ${tool}, fallback to cargo-binstall"

    install_cargo_binstall

    # By default, cargo-binstall enforce downloads over secure transports only.
    # As a result, http will be disabled, and it will also set
    # min tls version to be 1.2
    case "${version}" in
        latest) cargo binstall --force --no-confirm "${tool}" ;;
        *) cargo binstall --force --no-confirm --version "${version}" "${tool}" ;;
    esac
}
apt_update() {
    if type -P sudo &>/dev/null; then
        retry sudo apt-get -o Acquire::Retries=10 -qq update
    else
        retry apt-get -o Acquire::Retries=10 -qq update
    fi
    apt_updated=1
}
apt_install() {
    if [[ -z "${apt_updated:-}" ]]; then
        apt_update
    fi
    if type -P sudo &>/dev/null; then
        retry sudo apt-get -o Acquire::Retries=10 -qq -o Dpkg::Use-Pty=0 install -y --no-install-recommends "$@"
    else
        retry apt-get -o Acquire::Retries=10 -qq -o Dpkg::Use-Pty=0 install -y --no-install-recommends "$@"
    fi
}
apt_remove() {
    if type -P sudo &>/dev/null; then
        sudo apt-get -qq -o Dpkg::Use-Pty=0 remove -y "$@"
    else
        apt-get -qq -o Dpkg::Use-Pty=0 remove -y "$@"
    fi
}
snap_install() {
    if type -P sudo &>/dev/null; then
        retry sudo snap install "$@"
    else
        retry snap install "$@"
    fi
}
apk_install() {
    if type -P doas &>/dev/null; then
        doas apk add "$@"
    else
        apk add "$@"
    fi
}
dnf_install() {
    if type -P sudo &>/dev/null; then
        retry sudo "${dnf}" install -y "$@"
    else
        retry "${dnf}" install -y "$@"
    fi
}
sys_install() {
    case "${base_distro}" in
        debian) apt_install "$@" ;;
        alpine) apk_install "$@" ;;
        fedora) dnf_install "$@" ;;
    esac
}

if [[ $# -gt 0 ]]; then
    bail "invalid argument '$1'"
fi

export DEBIAN_FRONTEND=noninteractive

# Inputs
tool="${INPUT_TOOL:-}"
tools=()
if [[ -n "${tool}" ]]; then
    while read -rd,; do tools+=("${REPLY}"); done <<<"${tool},"
fi

# Refs: https://github.com/rust-lang/rustup/blob/HEAD/rustup-init.sh
case "$(uname -m)" in
    aarch64 | arm64) host_arch="aarch64" ;;
    xscale | arm | armv6l | armv7l | armv8l)
        # Ignore arm for now, as we need to consider the version and whether hard-float is supported.
        # https://github.com/rust-lang/rustup/pull/593
        # https://github.com/cross-rs/cross/pull/1018
        # Does it seem only armv7l is supported?
        # https://github.com/actions/runner/blob/6b9e8a6be411a6e63d5ccaf3c47e7b7622c5ec49/src/Misc/externals.sh#L174
        bail "32-bit ARM runner is not supported yet by this action"
        ;;
    # GitHub Actions Runner supports Linux (x86_64, aarch64, arm), Windows (x86_64, aarch64),
    # and macOS (x86_64, aarch64).
    # https://github.com/actions/runner
    # https://docs.github.com/en/actions/hosting-your-own-runners/about-self-hosted-runners#supported-architectures-and-operating-systems-for-self-hosted-runners
    # So we can assume x86_64 unless it is aarch64 or arm.
    *) host_arch="x86_64" ;;
esac
base_distro=""
exe=""
case "${OSTYPE}" in
    linux*)
        host_env="gnu"
        if (ldd --version 2>&1 || true) | grep -q 'musl'; then
            host_env="musl"
        fi
        if grep -q '^ID_LIKE=' /etc/os-release; then
            base_distro="$(grep '^ID_LIKE=' /etc/os-release | sed 's/^ID_LIKE=//')"
            case "${base_distro}" in
                *debian*) base_distro=debian ;;
                *alpine*) base_distro=alpine ;;
                *fedora*) base_distro=fedora ;;
            esac
        else
            base_distro="$(grep '^ID=' /etc/os-release | sed 's/^ID=//')"
        fi
        case "${base_distro}" in
            fedora)
                dnf=dnf
                if ! type -P dnf &>/dev/null; then
                    if type -P microdnf &>/dev/null; then
                        # fedora-based distributions have "minimal" images that
                        # use microdnf instead of dnf.
                        dnf=microdnf
                    else
                        # If neither dnf nor microdnf is available, it is
                        # probably an RHEL7-based distribution that does not
                        # have dnf installed by default.
                        dnf=yum
                    fi
                fi
                ;;
        esac
        ;;
    cygwin* | msys*) exe=".exe" ;;
esac

cargo_bin="${CARGO_HOME:-"${HOME}/.cargo"}/bin"
if [[ ! -d "${cargo_bin}" ]]; then
    cargo_bin=/usr/local/bin
fi

if ! type -P curl &>/dev/null || ! type -P tar &>/dev/null; then
    case "${base_distro}" in
        debian | alpine | fedora) sys_install ca-certificates curl tar ;;
    esac
fi

for tool in "${tools[@]}"; do
    if [[ "${tool}" == *"@"* ]]; then
        version="${tool#*@}"
        if [[ ! "${version}" =~ ^([1-9][0-9]*(\.[0-9]+(\.[0-9]+)?)?|0\.[1-9][0-9]*(\.[0-9]+)?|^0\.0\.[0-9]+)(-[0-9A-Za-z\.-]+)?(\+[0-9A-Za-z\.-]+)?$|^latest$ ]]; then
            bail "install-action does not support semver operators"
        fi
    else
        version="latest"
    fi
    tool="${tool%@*}"
    bin="${tool}${exe}"
    info "installing ${tool}@${version}"
    case "${tool}" in
        cargo-hack | cargo-llvm-cov | cargo-minimal-versions | parse-changelog)
            case "${tool}" in
                # https://github.com/taiki-e/cargo-hack/releases
                cargo-hack) latest_version="0.5.24" ;;
                # https://github.com/taiki-e/cargo-llvm-cov/releases
                cargo-llvm-cov) latest_version="0.5.2" ;;
                # https://github.com/taiki-e/cargo-minimal-versions/releases
                cargo-minimal-versions) latest_version="0.1.8" ;;
                # https://github.com/taiki-e/parse-changelog/releases
                parse-changelog) latest_version="0.5.2" ;;
                *) exit 1 ;;
            esac
            repo="taiki-e/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            case "${OSTYPE}" in
                linux*) target="${host_arch}-unknown-linux-musl" ;;
                darwin*) target="${host_arch}-apple-darwin" ;;
                cygwin* | msys*)
                    case "${tool}" in
                        cargo-llvm-cov) target="x86_64-pc-windows-msvc" ;;
                        *) target="${host_arch}-pc-windows-msvc" ;;
                    esac
                    ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            url="https://github.com/${repo}/releases/download/v${version}/${tool}-${target}.tar.gz"
            download "${url}" "${cargo_bin}" "${tool}${exe}"
            ;;
        cargo-udeps)
            # https://github.com/est31/cargo-udeps/releases
            latest_version="0.1.35"
            repo="est31/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            base_url="https://github.com/${repo}/releases/download/v${version}/${tool}-v${version}"
            case "${OSTYPE}" in
                linux*)
                    target="x86_64-unknown-linux-gnu"
                    url="${base_url}-${target}.tar.gz"
                    ;;
                darwin*)
                    target="x86_64-apple-darwin"
                    url="${base_url}-${target}.tar.gz"
                    ;;
                cygwin* | msys*)
                    target="x86_64-pc-windows-msvc"
                    url="${base_url}-${target}.zip"
                    ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            # leading `./` is required for cargo-udeps to work
            download "${url}" "${cargo_bin}" "./${tool}-v${version}-${target}/${tool}${exe}"
            ;;
        cargo-valgrind)
            # https://github.com/jfrimmel/cargo-valgrind/releases
            latest_version="2.1.0"
            repo="jfrimmel/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            base_url="https://github.com/${repo}/releases/download/v${version}/${tool}-${version}"
            case "${OSTYPE}" in
                linux*)
                    target="x86_64-unknown-linux-musl"
                    url="${base_url}-${target}.tar.gz"
                    ;;
                darwin*)
                    target="x86_64-apple-darwin"
                    url="${base_url}-${target}.tar.gz"
                    ;;
                cygwin* | msys*)
                    target="x86_64-pc-windows-msvc"
                    url="${base_url}-${target}.zip"
                    ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            download "${url}" "${cargo_bin}" "${tool}${exe}"
            ;;
        cargo-deny)
            # https://github.com/EmbarkStudios/cargo-deny/releases
            latest_version="0.13.5"
            repo="EmbarkStudios/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            case "${OSTYPE}" in
                linux*) target="x86_64-unknown-linux-musl" ;;
                darwin*) target="${host_arch}-apple-darwin" ;;
                cygwin* | msys*) target="x86_64-pc-windows-msvc" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            url="https://github.com/${repo}/releases/download/${version}/${tool}-${version}-${target}.tar.gz"
            download "${url}" "${cargo_bin}" "${tool}-${version}-${target}/${tool}${exe}"
            ;;
        cross)
            # https://github.com/cross-rs/cross/releases
            latest_version="0.2.4"
            repo="cross-rs/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            case "${OSTYPE}" in
                linux*) target="x86_64-unknown-linux-musl" ;;
                darwin*) target="x86_64-apple-darwin" ;;
                cygwin* | msys*) target="x86_64-pc-windows-msvc" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            case "${version}" in
                0.1.* | 0.2.[0-1]) url="https://github.com/${repo}/releases/download/v${version}/${tool}-v${version}-${target}.tar.gz" ;;
                *) url="https://github.com/${repo}/releases/download/v${version}/${tool}-${target}.tar.gz" ;;
            esac
            download "${url}" "${cargo_bin}" "${tool}${exe}"
            ;;
        nextest | cargo-nextest)
            bin="cargo-nextest"
            # https://nexte.st/book/pre-built-binaries.html
            case "${OSTYPE}" in
                linux*)
                    # musl build of nextest is slow, so use glibc build if host_env is gnu.
                    # https://github.com/taiki-e/install-action/issues/13
                    case "${host_env}" in
                        gnu) url="https://get.nexte.st/${version}/linux" ;;
                        *) url="https://get.nexte.st/${version}/linux-musl" ;;
                    esac
                    ;;
                darwin*) url="https://get.nexte.st/${version}/mac" ;;
                cygwin* | msys*) url="https://get.nexte.st/${version}/windows-tar" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            info "downloading ${url}"
            retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 "${url}" \
                | tar xzf - -C "${cargo_bin}"
            ;;
        protoc)
            # https://github.com/protocolbuffers/protobuf/releases
            latest_version="3.21.12"
            repo="protocolbuffers/protobuf"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            miner_patch_version="${version#*.}"
            base_url="https://github.com/${repo}/releases/download/v${miner_patch_version}/protoc-${miner_patch_version}"
            # Copying files to /usr/local/include requires sudo, so do not use it.
            bin_dir="${HOME}/.install-action/bin"
            include_dir="${HOME}/.install-action/include"
            if [[ ! -d "${bin_dir}" ]]; then
                mkdir -p "${bin_dir}"
                mkdir -p "${include_dir}"
                echo "${bin_dir}" >>"${GITHUB_PATH}"
                export PATH="${PATH}:${bin_dir}"
            fi
            case "${OSTYPE}" in
                linux*) url="${base_url}-linux-${host_arch/aarch/aarch_}.zip" ;;
                darwin*) url="${base_url}-osx-${host_arch/aarch/aarch_}.zip" ;;
                cygwin* | msys*) url="${base_url}-win64.zip" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            if ! type -P unzip &>/dev/null; then
                case "${base_distro}" in
                    debian | alpine | fedora) sys_install unzip ;;
                esac
            fi
            mkdir -p .install-action-tmp
            (
                cd .install-action-tmp
                info "downloading ${url}"
                retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 "${url}" -o tmp.zip
                unzip tmp.zip
                mv "bin/protoc${exe}" "${bin_dir}/"
                mkdir -p "${include_dir}/"
                cp -r include/. "${include_dir}/"
                case "${OSTYPE}" in
                    cygwin* | msys*) bin_dir=$(sed <<<"${bin_dir}" 's/^\/c\//C:\\/') ;;
                esac
                if [[ -z "${PROTOC:-}" ]]; then
                    info "setting PROTOC environment variable"
                    echo "PROTOC=${bin_dir}/protoc${exe}" >>"${GITHUB_ENV}"
                fi
            )
            rm -rf .install-action-tmp
            ;;
        shellcheck)
            # https://github.com/koalaman/shellcheck/releases
            latest_version="0.9.0"
            repo="koalaman/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            base_url="https://github.com/${repo}/releases/download/v${version}/${tool}-v${version}"
            bin="${tool}-v${version}/${tool}${exe}"
            case "${OSTYPE}" in
                linux*)
                    if type -P shellcheck &>/dev/null; then
                        apt_remove shellcheck
                    fi
                    url="${base_url}.linux.${host_arch}.tar.xz"
                    ;;
                darwin*) url="${base_url}.darwin.x86_64.tar.xz" ;;
                cygwin* | msys*)
                    url="${base_url}.zip"
                    bin="${tool}${exe}"
                    ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            download "${url}" /usr/local/bin "${bin}"
            ;;
        shfmt)
            # https://github.com/mvdan/sh/releases
            latest_version="3.6.0"
            repo="mvdan/sh"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            bin_dir="/usr/local/bin"
            case "${OSTYPE}" in
                linux*)
                    case "${host_arch}" in
                        aarch64) target="linux_arm64" ;;
                        *) target="linux_amd64" ;;
                    esac
                    ;;
                darwin*)
                    case "${host_arch}" in
                        aarch64) target="darwin_arm64" ;;
                        *) target="darwin_amd64" ;;
                    esac
                    ;;
                cygwin* | msys*)
                    target="windows_amd64"
                    bin_dir="${HOME}/.install-action/bin"
                    if [[ ! -d "${bin_dir}" ]]; then
                        mkdir -p "${bin_dir}"
                        echo "${bin_dir}" >>"${GITHUB_PATH}"
                        export PATH="${PATH}:${bin_dir}"
                    fi
                    ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            url="https://github.com/${repo}/releases/download/v${version}/${tool}_v${version}_${target}${exe}"
            info "downloading ${url}"
            retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 -o "${bin_dir}/${tool}${exe}" "${url}"
            case "${OSTYPE}" in
                linux* | darwin*) chmod +x "${bin_dir}/${tool}${exe}" ;;
            esac
            ;;
        valgrind)
            case "${version}" in
                latest) ;;
                *) warn "specifying the version of ${tool} is not supported yet by this action" ;;
            esac
            case "${OSTYPE}" in
                linux*) ;;
                darwin* | cygwin* | msys*) bail "${tool} for non-linux is not supported yet by this action" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            # libc6-dbg is needed to run Valgrind
            apt_install libc6-dbg
            # Use snap to install the latest Valgrind
            # https://snapcraft.io/install/valgrind/ubuntu
            snap_install valgrind --classic
            ;;
        wasm-pack)
            # https://github.com/rustwasm/wasm-pack/releases
            latest_version="0.10.3"
            repo="rustwasm/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            case "${OSTYPE}" in
                linux*) target="${host_arch}-unknown-linux-musl" ;;
                darwin*) target="x86_64-apple-darwin" ;;
                cygwin* | msys*) target="x86_64-pc-windows-msvc" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            url="https://github.com/${repo}/releases/download/v${version}/${tool}-v${version}-${target}.tar.gz"
            download "${url}" "${cargo_bin}" "${tool}-v${version}-${target}/${tool}${exe}"
            ;;
        wasmtime)
            # https://github.com/bytecodealliance/wasmtime/releases
            latest_version="3.0.1"
            repo="bytecodealliance/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            base_url="https://github.com/${repo}/releases/download/v${version}/${tool}-v${version}"
            case "${OSTYPE}" in
                linux*)
                    target="${host_arch}-linux"
                    url="${base_url}-${target}.tar.xz"
                    ;;
                darwin*)
                    target="${host_arch}-macos"
                    url="${base_url}-${target}.tar.xz"
                    ;;
                cygwin* | msys*)
                    target="x86_64-windows"
                    url="${base_url}-${target}.zip"
                    ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            download "${url}" "${cargo_bin}" "${tool}-v${version}-${target}/${tool}${exe}"
            ;;
        mdbook)
            # https://github.com/rust-lang/mdBook/releases
            latest_version="0.4.23"
            repo="rust-lang/mdBook"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            base_url="https://github.com/${repo}/releases/download/v${version}/${tool}-v${version}"
            case "${OSTYPE}" in
                linux*) url="${base_url}-x86_64-unknown-linux-gnu.tar.gz" ;;
                darwin*) url="${base_url}-x86_64-apple-darwin.tar.gz" ;;
                cygwin* | msys*) url="${base_url}-x86_64-pc-windows-msvc.zip" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            download "${url}" "${cargo_bin}" "${tool}${exe}"
            ;;
        mdbook-linkcheck)
            # https://github.com/Michael-F-Bryan/mdbook-linkcheck/releases
            latest_version="0.7.7"
            repo="Michael-F-Bryan/${tool}"
            case "${version}" in
                latest) version="${latest_version}" ;;
            esac
            case "${OSTYPE}" in
                linux*) target="x86_64-unknown-linux-gnu" ;;
                darwin*) target="x86_64-apple-darwin" ;;
                cygwin* | msys*) target="x86_64-pc-windows-msvc" ;;
                *) bail "unsupported OSTYPE '${OSTYPE}' for ${tool}" ;;
            esac
            url="https://github.com/${repo}/releases/download/v${version}/${tool}.${target}.zip"
            download "${url}" "${cargo_bin}" "${tool}${exe}"
            case "${OSTYPE}" in
                linux* | darwin*) chmod +x "${cargo_bin}/${tool}${exe}" ;;
            esac
            ;;
        cargo-binstall)
            install_cargo_binstall
            echo
            continue
            ;;
        *)
            cargo_binstall "${tool}" "${version}"
            continue
            ;;
    esac

    info "${tool} installed at $(type -P "${bin}")"
    case "${bin}" in
        "cargo-udeps${exe}") x cargo udeps --help | head -1 ;; # cargo-udeps v0.1.30 does not support --version option
        "cargo-valgrind${exe}") x cargo valgrind --help ;;     # cargo-valgrind v2.1.0 does not support --version option
        cargo-*) x cargo "${tool#cargo-}" --version ;;
        *) x "${tool}" --version ;;
    esac
    echo
done
