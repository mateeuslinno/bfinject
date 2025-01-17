#!/jb/bin/bash

CYCRIPT_PORT=1337

function help {
    echo "Syntax: $0 [-p PID | -P appname] [-l /path/to/yourdylib | -L feature]"
    echo
    echo For example:
    echo "   $0 -P Reddit.app -l /path/to/evil.dylib   # Injects evil.dylib into the Reddit app"
    echo "     or"
    echo "   $0 -p 1234 -L cycript                     # Inject Cycript into PID"
    echo "     or "
    echo "   $0 -p 4566 -l /path/to/evil.dylib         # Injects the .dylib of your choice into PID"
    echo 
    echo "Instead of specifying the PID with -p, bfinject can search for the correct PID based on the app name."
    echo "Just enter \"-P identifier\" where \"identifier\" is a string unique to your app, e.g. \"fing.app\"."
    echo
    echo Available features:
    echo "  cycript    - Inject and run Cycript"
    echo "  decrypt    - Create a decrypted copy of the target app"
    echo "  test       - Inject a simple .dylib to make an entry in the console log"
    echo "  ispy       - Inject iSpy. Browse to http://<DEVICE_IP>:31337/"
    echo
}


#
# check args
#
if [ "$1" != "-p" ] && [ "$1" != "-P" ]; then
    help
    exit 1
fi

if [ "$3" != "-l" -a "$3" != "-L" ]; then
    help
    exit 1
fi

if [ "$1" == "-p" ]; then
    PID=$2
else
    count=`ps axwww|grep "$2"|grep container|grep '.app'|grep -v grep |wc -l|sed 's/ //g'`
    if [ "$count" != "1" ]; then  
        echo "[!] \"$2\" was not uniquely found, please check your criteria."
        exit 1
    fi
    PID=`ps awwwx|grep "$2"|grep container|grep '.app'|grep -v grep|sed 's/^\ *//g'|cut -f1 -d\ `
    bad=1
    case "$PID" in
        ''|*[!0-9]*) bad=1 ;;
        *) bad=0 ;;
    esac
    if [ "$bad" != "0" ]; then
        echo "[!] Process not found for string \"$3\""
        exit 1
    fi
fi

declare -a DYLIBS

if [ "$3" == "-l" ]; then
    FEATURE=""
    DYLIBS=("$4")
else
    FEATURE="$4"

    case "$FEATURE" in
        cycript)
            DYLIBS=(dylibs/cycript.dylib dylibs/cycript-runner.dylib)
            ;;
        
        decrypt)
            DYLIBS=(dylibs/bfdecrypt.dylib)
            ;;

        test)
            DYLIBS=(dylibs/simple.dylib)
            ;;
        ispy)
            DYLIBS=(dylibs/iSpy.dylib)
            ;;
        iSpy)
            DYLIBS=(dylibs/iSpy.dylib)
            ;;
        default)
            help
            exit 1
            ;;
    esac
fi


#
# Be a good netizen and tidy up your litter
#
function clean_up {
    if [ -d "$DYLIB_DIR" ] && [ "$DYLIB_DIR" != "/System/Library/Frameworks" ]; then
        rm -rf "$DYLIB_DIR" >/dev/null 2>&1
    fi
    rm -f "$RANDOM_NAME" > /dev/null 2>&1
    rm -f /electra/usr/local/bin/bfinject4realz > /dev/null 2>&1
    rm -f /electra/usr/local/bin/jtool.liberios > /dev/null 2>&1
}


#
# Entitlements for dylib injection and for our injector binary.
#
if [ ! -f entitlements.xml ]; then
    cat > entitlements.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>platform-application</key>
        <true/>
        <key>get-task-allow</key>
        <true/>
        <key>task_for_pid-allow</key>
        <true/>
        <key>com.apple.system-task-ports</key>
        <true/>
    </dict>
</plist>
EOF
fi


#
# Detect LiberiOS vs Electra
#
if [ -f /electra/inject_criticald ]; then
    # This is Electra >= 1.0.2
    echo "[+] Electra detected."
    mkdir -p /electra/usr/local/bin
    cp jtool.liberios /electra/usr/local/bin/
    chmod +x /electra/usr/local/bin/jtool.liberios
    JTOOL=/electra/usr/local/bin/jtool.liberios
    cp bfinject4realz /electra/usr/local/bin/
    INJECTOR=/electra/usr/local/bin/bfinject4realz
elif [ -f /bootstrap/inject_criticald ]; then
    # This is Electra < 1.0.2
    echo "[+] Electra detected."
    cp jtool.liberios /bootstrap/usr/local/bin/
    chmod +x /bootstrap/usr/local/bin/jtool.liberios
    JTOOL=/bootstrap/usr/local/bin/jtool.liberios
    cp bfinject4realz /bootstrap/usr/local/bin/
    INJECTOR=/bootstrap/usr/local/bin/bfinject4realz
elif [ -f /jb/usr/local/bin/jtool ]; then
    # This is LiberiOS
    echo "[+] Liberios detected"
    JTOOL=jtool
    INJECTOR=`pwd`/bfinject4realz
else
    echo "[!] Unknown jailbreak. Aborting."
    exit 1
fi


#
# Do the actual injection into the remote process
#
for DYLIB in ${DYLIBS[@]}; do
    if [ ! -f "$DYLIB" ]; then
        echo "$DYLIB" doesn\'t exist
        clean_up
        exit 1
    fi
    
    # Use random filenames to avoid cached binaries causing "Killed: 9" messages.
    RAND=`dd if=/dev/random bs=1 count=16 2>/dev/null | md5sum`
    RANDOM_NAME="${INJECTOR%/*}/`dd if=/dev/random bs=1 count=16 2>/dev/null | md5sum`"
    DYLIB_DIR="/System/Library/Frameworks/${RAND}.framework"
    DYLIB_PATH="$DYLIB_DIR/$RAND.dylib"

    # We'll give the injector as a random filename
    cp "$INJECTOR" "$RANDOM_NAME"
    chmod +x "$RANDOM_NAME"

    #
    # Find the full path to the target app binary
    #
    BINARY=`ps -o pid,command $PID|tail -n1|sed 's/^\ *//g'|cut -f2- -d\ `
    if [ "$BINARY" == "COMMAND" ]; then 
        echo "[!] ERROR: PID $PID not found."
        clean_up
        exit 1
    fi
    echo "[+] Injecting into '$BINARY'"

    #
    # Get the Team ID that signed the target app's binary.
    # We need this so we can re-sign the injected .dylib to fool the kernel
    # into assuming the .dylib is part of the injectee bundle.
    # This allows is to map the .dylib into the target's process space via dlopen().
    #
    echo "[+] Getting Team ID from target application..."
    TEAMID=`$JTOOL --ent "$BINARY" 2> /dev/null | grep -A1 'com.apple.developer.team-identifier' | tail -n1 |sed 's/ //g'|cut -f2 -d\>|cut -f1 -d\<`
    if [ "$TEAMID" == "" ]; then
        echo "[+] WARNING: No Team ID found. Continuing regardless, but expect weird stuff to happen."
    fi

    #
    # Move the injectee dylib to a sandbox-friendly location
    #
    mkdir "$DYLIB_DIR"
    cp "$DYLIB" "$DYLIB_PATH"

    #
    # Thin the binary so that it's not FAT and contains only an arm64 image
    echo "[+] Thinning dylib into non-fat arm64 image"
    $JTOOL -arch arm64 -e arch "$DYLIB_PATH" >/dev/null 2>&1
    if [ "$?" == "0" ]; then
        rm -f "$DYLIB_PATH"
        DYLIB_PATH="${DYLIB_PATH}.arch_arm64"
    else
        echo "[!] WARNING: Wasn't able to thin the dylib."
    fi

    #
    # Sign platform entitlements and Team ID into our dylib
    #
    echo "[+] Signing injectable .dylib with Team ID $TEAMID and platform entitlements..."
    $JTOOL --sign platform --ent entitlements.xml --inplace --teamid "$TEAMID" "$DYLIB_PATH" > /dev/null 2>&1
    if [ "$?" != "0" ]; then
        echo jtool dylib signing error. barfing.
        clean_up
        exit 1
    fi

    #
    # Sign the randomly-renamed injector binary with  platform entitlements
    #
    $JTOOL --sign platform --ent entitlements.xml --inplace "$RANDOM_NAME" >/dev/null 2>&1
    if [ "$?" != "0" ]; then
        echo jtool "$RANDOM_NAME" signing error. barfing.
        clean_up
        exit 1
    fi

    #
    # Inject!
    #
    "$RANDOM_NAME" "$PID" "$DYLIB_PATH"
done

#
# EOF
#
echo "[+] So long and thanks for all the fish."
clean_up
exit 0
