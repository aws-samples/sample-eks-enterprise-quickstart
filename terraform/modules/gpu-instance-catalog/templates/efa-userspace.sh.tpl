if [ ! -x /opt/amazon/efa/bin/fi_info ]; then
  EFA_PKGS_RECORD=/opt/amazon/efa_installed_packages
  EFA_FALLBACK_VERSION="${ efa_installer_version != "" ? efa_installer_version : "latest" }"
  AMI_EFA_VERSION=""
  if [ -f "$EFA_PKGS_RECORD" ]; then
    AMI_EFA_VERSION=$(sed -n 's/^# EFA installer version: *\([0-9][0-9.]*\).*$/\1/p' "$EFA_PKGS_RECORD" | head -n 1)
  fi
  if [[ "$AMI_EFA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    EFA_VERSION="$AMI_EFA_VERSION"
    echo "EFA installer version $EFA_VERSION (from AMI record $EFA_PKGS_RECORD)"
    if [ "$EFA_FALLBACK_VERSION" != "$EFA_VERSION" ]; then
      echo "NOTE: efa_installer_version=$EFA_FALLBACK_VERSION not used — AMI record wins so kmod/rdma-core/libfabric stay on one release"
    fi
  else
    EFA_VERSION="$EFA_FALLBACK_VERSION"
    echo "WARN: no EFA installer version recorded in $EFA_PKGS_RECORD; falling back to efa_installer_version=$EFA_VERSION (kmod and userspace may come from different releases)"
  fi

  # Runs in a subshell (cd + early returns stay contained). Each step is
  # checked explicitly because `set -e` is suspended inside `( ... ) ||`.
  efa_userspace_install() {
    local base=https://efa-installer.amazonaws.com
    local tarball="aws-efa-installer-$EFA_VERSION.tar.gz"
    local rc=0
    cd "$EFA_WORKDIR" || return 1
    echo "=== Installing EFA userspace ($tarball, --skip-kmod) ==="
    if ! { curl -fsSLO "$base/$tarball" && curl -fsSLO "$base/$tarball.sig" && curl -fsSLO "$base/aws-efa-installer.key"; }; then
      echo "ERROR: failed to download $tarball (+ .sig / signing key) from $base"
      return 1
    fi
    # AL2023 ships gnupg2-minimal: no gpg-agent (so `gpg --import` fails with
    # "can't connect to the gpg-agent"), no gpgv, no --trust-model. Verify
    # against a dearmored keyring file instead — neither step needs the agent.
    # (The AMI build swaps in gnupg2-full for its import; we avoid a boot-time
    # dnf dependency.) Verified on gnupg2-minimal 2.3.7 (AL2023 EKS AMI).
    mkdir -m 700 "$EFA_WORKDIR/gnupg" || return 1
    if ! GNUPGHOME="$EFA_WORKDIR/gnupg" gpg --batch --yes --dearmor -o "$EFA_WORKDIR/efa-keyring.gpg" aws-efa-installer.key; then
      echo "ERROR: failed to read the EFA signing key"
      return 1
    fi
    # VALIDSIG's last field is the primary-key fingerprint of the signer.
    if ! GNUPGHOME="$EFA_WORKDIR/gnupg" gpg --batch --no-default-keyring --keyring "$EFA_WORKDIR/efa-keyring.gpg" \
        --status-fd 1 --verify "$tarball.sig" "$tarball" 2>/dev/null \
        | grep -Eq '^\[GNUPG:\] VALIDSIG .* 4E9091BCBB97A96B26B15E59A05480B1DD2D3CCC$'; then
      echo "ERROR: $tarball is not validly signed by the AWS EFA key — refusing to run the installer"
      return 1
    fi
    if ! tar -xf "$tarball"; then
      echo "ERROR: failed to extract $tarball"
      return 1
    fi
    rm -f "$tarball"
    cd aws-efa-installer || return 1
    # Full log kept on disk; the exit code is the installer's own (piping
    # straight into `tail` would report tail's status and hide failures).
    ./efa_installer.sh -y --skip-kmod > /var/log/efa-installer.log 2>&1 || rc=$?
    tail -n 30 /var/log/efa-installer.log
    if [ "$rc" -ne 0 ]; then
      echo "WARN: efa_installer.sh exited $rc (full log: /var/log/efa-installer.log)"
    fi
    return "$rc"
  }

  # /tmp is tmpfs on AL2023 and the tarball is ~650 MB: always clean up.
  if EFA_WORKDIR=$(mktemp -d /tmp/efa-installer.XXXXXX); then
    ( efa_userspace_install ) || \
      echo "WARN: EFA userspace install did not complete; containers with their own libfabric will still work"
    rm -rf "$EFA_WORKDIR"
  else
    echo "WARN: mktemp failed; skipping EFA userspace install"
  fi

  if [ -x /opt/amazon/efa/bin/fi_info ]; then
    echo "EFA userspace installed at /opt/amazon/efa/"
    echo "  installer release : $(sed -n 's/^# EFA installer version: *//p' "$EFA_PKGS_RECORD" 2>/dev/null | head -n 1)"
    echo "  efa kmod          : $(cat /sys/module/efa/version 2>/dev/null || modinfo -F version efa 2>/dev/null || echo unknown)"
    echo "  libfabric         : $(/opt/amazon/efa/bin/fi_info --version 2>/dev/null | head -n 1)"
    rpm -q rdma-core libibverbs libfabric-aws 2>/dev/null || true
  fi
fi
