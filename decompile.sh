#!/bin/sh
#
# Tool to decompile Renault R-Link Java Apps
#

BS_VER=2.0.3
D2J_VER=0.0.9.15
APK_VER=2.0.0b9

U_BAKSMALI=https://smali.googlecode.com/files/baksmali-$BS_VER.jar
U_SMALI=https://smali.googlecode.com/files/smali-$BS_VER.jar
U_D2J=http://dex2jar.googlecode.com/files/dex2jar-$D2J_VER.zip
U_JD=https://github.com/nviennot/jd-core-java/archive/master.zip
# http://android-apktool.googlecode.com/files/apktool$APK_VER.tar.bz2
U_APKTOOL=http://connortumbleson.com/apktool/test_versions/apktool_$APK_VER.jar?ref=blog-post

usage() {
    echo "Reverse Engineering R-Link filesystem"
    echo "$0 <filesystem>"
    echo "   <filesystem> - directory of unpacked android filesystem"
    exit 1
}

build_jd() {
   unzip -q -u jd-core-java.zip
   pushd jd-core-java-master
   ./gradlew assemble
   cp build/libs/jd-core-java-1.2.jar ..
   popd
}

get_sw_support() {
   wget -c $U_BAKSMALI
   wget -c $U_SMALI
   wget -c $U_D2J
   unzip -q -u dex2jar-$D2J_VER.zip
   wget -c $U_JD -O jd-core-java.zip
   build_jd
   wget -c $U_APKTOOL -O apktool_$APK_VER.jar
   return
}

test -z "$1" && usage
TARGET="$1"
test -d "$TARGET" || usage
FW=$TARGET/framework

get_sw_support

for i in $TARGET/app/*.odex; do
   name1=`basename -s.odex $i`
   name2=`dirname $i`/$name1
   echo -n "$name1: baksmali"
   # ODEX -> smali
   rm -rf "$name1"
   java -jar baksmali-$BS_VER.jar -a 9 -x $i -d $FW -o $name1
   # smali -> dex
   echo -n ", smali"
   java -jar smali-$BS_VER.jar -o classes.dex $name1
   rm -rf "$name1"
   # dex -> jar -> $name1.apk
   echo -n ", dex2jar"
   dex2jar-$D2J_VER/d2j-dex2jar.sh -f -o $name1.jar classes.dex 2>/dev/null
   rm classes.dex
   # decompile
   echo -n ", decompiling"
   java -jar jd-core-java-1.2.jar $name1.jar $name1 2>/dev/null
   cd $name1
   zip -q -r ../$name1.apk *
   cd ..
   rm -rf $name1 $name1.jar
   # apktool for resources -> $name1
   echo -n ", apktool"
   java -jar apktool_$APK_VER.jar d --no-src $name2.apk >/dev/null
   # join resources and sources
   unzip -q -o $name1.apk -d $name1
   cd $name1
   zip -q -r ../$name1.zip *
   cd ..
   rm -rf $name1 $name1.apk
   # finished
   echo ", ok"
done
