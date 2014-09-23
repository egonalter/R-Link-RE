#!/bin/bash

URL="http://www.codesourcery.com/sgpp/lite/arm/portal/package4571/public/arm-none-linux-gnueabi"
FILE="arm-2009q1-203-arm-none-linux-gnueabi"
EXT="src.tar.bz2"

echo "Downloading toolchain source archive..."
wget -c "$URL/$FILE.$EXT"

rm toolchain.diff
echo "Downloading TomTom patch..."
wget "http://www.tomtom.com/gpl/arm11/toolchain.diff"
dos2unix toolchain.diff

echo "Cleaning Toolchain..."
rm -rf $FILE

echo "Extracting Toolchain..."
tar -xjf $FILE.$EXT

pushd $FILE
  mkdir src
  for i in *.tar.bz2; do
       echo "... Extracting $i"
       tar -C src -xjf $i
  done

  pushd src
    echo "... Applying TomTom patch"
    patch -p1 < ../../toolchain.diff

    echo "... Applying build fixes"
    patch -p1 < ../../linux-2.6.28.10-unifdef-getline.patch

# first lines are bogus
    tail -n+2 build.sh > build2.sh && mv build2.sh ../build.sh
    tail -n+2 functions > functions2 && mv functions2 ../functions
  popd
  chmod +x build.sh

# no p4 here
  sed -i "s/^p4clist.*/p4clist=\"2009q1_203-474426\"/" build.sh
  sed -i "s/error \"Could not get perforce changelist\"//" build.sh

  echo "Building!!!"
  ./build.sh
popd
