#!/bin/bash

if [ -z "$CROSS_COMPILE" ]
then
  echo "Must export \$CROSS_COMPILE (set it to "none" for none)" >&2
  exit 1
fi

[ "$CROSS_COMPILE" == none ] && unset CROSS_COMPILE

# Must be absolute path

[ -z "$OUT" ] && OUT="$PWD/out"

[ -z "$CPUS" ] && CPUS=$(($(nproc)+1))

echo === download source

download()
{
  X=0
  while true
  do
    FILE="$(basename "$2")"
    [ "$(sha1sum "packages/$FILE" 2>/dev/null | awk '{print $1}')" == "$1" ] &&
      echo "$FILE" confirmed &&
      break
    [ $X -eq 1 ] && break
    X=1
    rm -f "packages/$FILE"
    wget "$2" -O "packages/$FILE"
  done
}

mkdir -p packages

download 7bdf7253d5a5dbf7073e8f5ca0999a7928a63dae \
  http://landley.net/toybox/downloads/toybox-0.6.1.tar.gz

download 157d14d24748b4505b1a418535688706a2b81680 \
  http://www.busybox.net/downloads/busybox-1.24.1.tar.bz2

echo === Create files and directories

rm -rf "$OUT" &&
mkdir -p "$OUT"/{etc,tmp,proc,sys,dev,home,mnt,root,usr/{bin,sbin,lib}} &&
chmod a+rwxt "$OUT"/tmp &&
ln -s usr/bin "$OUT/bin" &&
ln -s usr/sbin "$OUT/sbin" &&
ln -s usr/lib "$OUT/lib" &&

cat > "$OUT"/init << 'EOF' &&
#!/bin/hush

export HOME=/home
export PATH=/bin:/sbin

mountpoint -q proc || mount -t proc proc proc
mountpoint -q sys || mount -t sysfs sys sys
if ! mountpoint -q dev
then
  mount -t devtmpfs dev dev || mdev -s
  mkdir -p dev/pts
  mountpoint -q dev/pts || mount -t devpts dev/pts dev/pts
fi

# Setup networking for QEMU (needs /proc)
ifconfig eth0 10.0.2.15
route add default gw 10.0.2.2
[ "$(date +%s)" -lt 1000 ] && rdate 10.0.2.2 # or time-b.nist.gov
[ "$(date +%s)" -lt 10000000 ] && ntpd -nq -p north-america.pool.ntp.org

[ -z "$CONSOLE" ] &&
  CONSOLE="$(sed -n 's@.* console=\(/dev/\)*\([^ ]*\).*@\2@p' /proc/cmdline)"

[ -z "$HANDOFF" ] && echo Type exit when done. && HANDOFF=/bin/hush
[ -z "$CONSOLE" ] && CONSOLE=console
exec /sbin/oneit -c /dev/"$CONSOLE" "$HANDOFF"
EOF
chmod +x "$OUT"/init &&

cat > "$OUT"/etc/passwd << 'EOF' &&
root::0:0:root:/home/root:/bin/sh
guest:x:500:500:guest:/home/guest:/bin/sh
EOF

cat > "$OUT"/etc/group << 'EOF' &&
root:x:0:
guest:x:500:
EOF

echo "nameserver 8.8.8.8" > "$OUT"/etc/resolv.conf || exit 1

# Extract packages into "build" subdirectory
 
rm -rf build && mkdir build && cd build || exit 1

echo === install toybox

tar xvzf ../packages/toybox-*.tar.gz && cd toybox-* &&
make defconfig &&
# Work around musl design flaw
sed -i 's/.*\(CONFIG_TOYBOX_MUSL_NOMMU_IS_BROKEN\).*/\1=y/' .config &&
LDFLAGS=--static PREFIX="$OUT" make toybox install &&
cd .. && rm -rf toybox-* || exit 1

echo === install busybox

tar xvjf ../packages/busybox-*.tar.bz2 && cd busybox-* &&
cat > mini.conf << EOF
CONFIG_DESKTOP=y
CONFIG_LFS=y
CONFIG_SHOW_USAGE=y
CONFIG_FEATURE_VERBOSE_USAGE=y
CONFIG_LONG_OPTS=y

CONFIG_BUNZIP2=y
CONFIG_BZIP2=y
CONFIG_GUNZIP=y
CONFIG_GZIP=y
CONFIG_UNXZ=y

CONFIG_TAR=y
CONFIG_FEATURE_TAR_CREATE=y
CONFIG_FEATURE_TAR_AUTODETECT=y
CONFIG_FEATURE_TAR_GNU_EXTENSIONS=y
CONFIG_FEATURE_TAR_OLDGNU_COMPATIBILITY=y
CONFIG_FEATURE_TAR_LONG_OPTIONS=y
CONFIG_FEATURE_TAR_FROM=y
CONFIG_FEATURE_SEAMLESS_BZ2=y
CONFIG_FEATURE_SEAMLESS_GZ=y
CONFIG_FEATURE_SEAMLESS_XZ=y

CONFIG_ROUTE=y

CONFIG_HUSH=y
CONFIG_HUSH_BASH_COMPAT=y
CONFIG_HUSH_BRACE_EXPANSION=y
CONFIG_HUSH_HELP=y
CONFIG_HUSH_INTERACTIVE=y
CONFIG_HUSH_SAVEHISTORY=y
CONFIG_HUSH_JOB=y
CONFIG_HUSH_TICK=y
CONFIG_HUSH_IF=y
CONFIG_HUSH_LOOPS=y
CONFIG_HUSH_CASE=y
CONFIG_HUSH_FUNCTIONS=y
CONFIG_HUSH_LOCAL=y
CONFIG_HUSH_RANDOM_SUPPORT=y
CONFIG_HUSH_EXPORT_N=y
CONFIG_HUSH_MODE_X=y
CONFIG_FEATURE_SH_IS_HUSH=y
CONFIG_FEATURE_BASH_IS_NONE=y

CONFIG_SH_MATH_SUPPORT=y
CONFIG_SH_MATH_SUPPORT_64=y
CONFIG_FEATURE_SH_EXTRA_QUIET=y

CONFIG_FEATURE_EDITING=y
CONFIG_FEATURE_TAB_COMPLETION=y
CONFIG_FEATURE_EDITING_FANCY_PROMPT=y
CONFIG_FEATURE_EDITING_ASK_TERMINAL=y

CONFIG_WGET=y
CONFIG_FEATURE_WGET_STATUSBAR=y

CONFIG_PING=y

CONFIG_VI=y
CONFIG_FEATURE_VI_COLON=y
CONFIG_FEATURE_VI_YANKMARK=y
CONFIG_FEATURE_VI_SEARCH=y
CONFIG_FEATURE_VI_USE_SIGNALS=y
CONFIG_FEATURE_VI_DOT_CMD=y
CONFIG_FEATURE_VI_READONLY=y
CONFIG_FEATURE_VI_SETOPTS=y
CONFIG_FEATURE_VI_SET=y
CONFIG_FEATURE_VI_WIN_RESIZE=y
CONFIG_FEATURE_VI_ASK_TERMINAL=y
CONFIG_FEATURE_VI_OPTIMIZE_CURSOR=y
EOF

make allnoconfig KCONFIG_ALLCONFIG=mini.conf &&
LDFLAGS=--static make install CONFIG_PREFIX="$OUT" -j $CPUS &&
cd .. && rm -rf busybox-* || exit 1

echo === create out.cpio.gz

(cd "$OUT" && find . | cpio -o -H newc | gzip) > out.cpio.gz

echo === Now build kernel with CONFIG_INITRAMFS_SOURCE="\"$OUT\""