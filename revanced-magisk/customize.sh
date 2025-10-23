. "$MODPATH/config"

ui_print ""
if [ -n "$MODULE_ARCH" ] && [ "$MODULE_ARCH" != "$ARCH" ]; then
	abort "ERROR: Wrong arch
Your device: $ARCH
Module: $MODULE_ARCH"
fi
if [ "$ARCH" = "arm" ]; then
	ARCH_LIB=armeabi-v7a
elif [ "$ARCH" = "arm64" ]; then
	ARCH_LIB=arm64-v8a
elif [ "$ARCH" = "x86" ]; then
	ARCH_LIB=x86
elif [ "$ARCH" = "x64" ]; then
	ARCH_LIB=x86_64
else abort "ERROR: unreachable: ${ARCH}"; fi
RVPATH=/data/adb/rvhc/${MODPATH##*/}.apk

set_perm_recursive "$MODPATH/bin" 0 0 0755 0777

if su -M -c true >/dev/null 2>/dev/null; then
	alias mm='su -M -c'
else alias mm='nsenter -t1 -m'; fi

mm grep -F "$PKG_NAME" /proc/mounts | while read -r line; do
	ui_print "* Un-mount"
	mp=${line#* } mp=${mp%% *}
	mm umount -l "${mp%%\\*}"
done
am force-stop "$PKG_NAME"

pmex() {
	OP=$(pm "$@" 2>&1 </dev/null)
	RET=$?
	echo "$OP"
	return $RET
}

if ! pmex path "$PKG_NAME" >&2; then
	if pmex install-existing "$PKG_NAME" >&2; then
		BASEPATH=$(pmex path "$PKG_NAME") || abort "ERROR: pm path failed $BASEPATH"
		echo >&2 "'$BASEPATH'"
		BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
		if [ "${BASEPATH:1:4}" = data ]; then
			if pmex uninstall -k --user 0 "$PKG_NAME" >&2; then
				rm -rf "$BASEPATH" 2>&1
				ui_print "* Cleared existing $PKG_NAME package"
				ui_print "* Reboot and reflash"
				abort
			else abort "ERROR: pm uninstall failed"; fi
		else ui_print "* Installed stock $PKG_NAME package"; fi
	fi
fi

IS_SYS=false
INS=true
if BASEPATH=$(pmex path "$PKG_NAME"); then
	echo >&2 "'$BASEPATH'"
	BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
	if [ "${BASEPATH:1:4}" != data ]; then
		ui_print "* $PKG_NAME is a system app."
		IS_SYS=true
	elif [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
		ui_print "* Stock $PKG_NAME APK was not found"
		VERSION=$(dumpsys package "$PKG_NAME" | grep -m1 versionName) VERSION="${VERSION#*=}"
		if [ "$VERSION" = "$PKG_VER" ] || [ -z "$VERSION" ]; then
			ui_print "* Skipping stock installation"
			INS=false
		else
			abort "ERROR: Version mismatch
			installed: $VERSION
			module:    $PKG_VER
			"
		fi
	elif "${MODPATH:?}/bin/$ARCH/cmpr" "$BASEPATH/base.apk" "$MODPATH/$PKG_NAME.apk"; then
		ui_print "* $PKG_NAME is up-to-date"
		INS=false
	fi
fi

install() {
	if [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
		abort "ERROR: Stock $PKG_NAME apk was not found"
	fi
	ui_print "* Updating $PKG_NAME to $PKG_VER"
	install_err=""
	VERIF1=$(settings get global verifier_verify_adb_installs)
	VERIF2=$(settings get global package_verifier_enable)
	settings put global verifier_verify_adb_installs 0
	settings put global package_verifier_enable 0
	SZ=$(stat -c "%s" "$MODPATH/$PKG_NAME.apk")
	for IT in 1 2; do
		if ! SES=$(pmex install-create --user 0 -i com.android.vending -r -d -S "$SZ"); then
			ui_print "ERROR: install-create failed"
			install_err="$SES"
			break
		fi
		ui_print "ERROR: install-commit failed"
		abort "$op"
	fi
	settings put global verifier_verify_adb_installs 1
	if BASEPATH=$(pm path "$PKG_NAME" 2>&1 </dev/null); then
		BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
	else
		abort "ERROR: install $PKG_NAME manually and reflash the module"
	fi
}
if [ $INS = true ] && ! install; then abort; fi
BASEPATHLIB=${BASEPATH}/lib/${ARCH}
if [ $INS = true ] || [ -z "$(ls -A1 "$BASEPATHLIB")" ]; then
	ui_print "* Extracting native libs"
	if [ ! -d "$BASEPATHLIB" ]; then mkdir -p "$BASEPATHLIB"; else rm -f "$BASEPATHLIB"/* >/dev/null 2>&1 || :; fi
	if ! op=$(unzip -o -j "$MODPATH/$PKG_NAME.apk" "lib/${ARCH_LIB}/*" -d "$BASEPATHLIB" 2>&1); then
		ui_print "ERROR: extracting native libs failed"
		abort "$op"
	fi
	set_perm_recursive "${BASEPATH}/lib" 1000 1000 755 755 u:object_r:apk_data_file:s0
fi

ui_print "* Setting Permissions"
set_perm "$MODPATH/base.apk" 1000 1000 644 u:object_r:apk_data_file:s0

ui_print "* Mounting $PKG_NAME"
mkdir -p "/data/adb/rvhc"
RVPATH=/data/adb/rvhc/${MODPATH##*/}.apk
mv -f "$MODPATH/base.apk" "$RVPATH"

if ! op=$(mm mount -o bind "$RVPATH" "$BASEPATH/base.apk" 2>&1); then
	ui_print "ERROR: Mount failed!"
	ui_print "$op"
fi
am force-stop "$PKG_NAME"
ui_print "* Optimizing $PKG_NAME"
nohup cmd package compile --reset "$PKG_NAME" >/dev/null 2>&1 &

ui_print "- Cleanup"
rm -rf "${MODPATH:?}/bin" "$MODPATH/$PKG_NAME.apk"

ui_print "- Done"
ui_print " "
