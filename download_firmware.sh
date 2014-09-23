#!/bin/bash

URL="http://download.tomtom.com/sweet/navcore"
ROM="system-update_"$1"_all.ttpkg"
ROM2=`basename -s.ttpkg $ROM`

if [ "$1*" == "*" ]; then
   echo $0 "<r-link-version>"
   echo "   <r-link-version> - TomTom released version, e.g. 1467818"
   exit 1
fi

echo "Downloading..."

wget -qc "$URL/$ROM"

echo "Convert to TAR archive..."

while :; do
   dd conv=notrunc bs=102400 iflag=skip_bytes,fullblock \
       oflag=append skip=20 count=1 2>&1 >&3 | grep 0+1 && break
done < <(tail -c +9 $ROM) 3>&1 | tail -c +55 > $ROM2.tar

echo "Extracting ..."

mkdir -p $ROM2
pushd $ROM2 > /dev/null
  tar -xf ../$ROM2.tar
  ls -lR
popd > /dev/null

echo "Finished. Now you can mount root.img.new."
