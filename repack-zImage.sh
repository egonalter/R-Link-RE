#!/bin/bash

version="Version 6,  by mizch <hcz@hczim.de>
Time-stamp: <2011-05-03 20:14:30 hcz>

Please refer to the thread on http://www.xda-developers.com for
questions and remarks about this program."

# Copyright (C) 2011 by Heike C. Zimmerer <hcz@hczim.de>
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License. For
# details see <http://www.gnu.org/licenses/>.


### Preparation:
# You should have received cpio_set0 along with this program.
# Copy it into /usr/local/bin.
#
# The program will run without this (and emit an info message about
# using the normal cpio).  However, the compession result of the
# initramfs will be smaller and consistent if you use it.


### What the program does:
usage(){
    echo "\
Usage: $pname [-v] -u|-p|-z [<file name, default: zImage>]
Function: [Un]Pack a zImage (for modification, mainly of the initramfs)
Opts:
   -u         unpack an Image
   -p         pack an image from a directory structure created by
              a previous unpack
   -z         create <file name>.tar from <file name> (simple tar, nothing fancy)
   --version  print version info
   --help     print this help
   Play with the following three options to get best compression results:
   -s         use standard cpio (default: uses cpio_set0 if available)
   -g         use gen_init_cpio instead of cpio/cpio_set0 (ignores -s)
   -r         don't reorder initramfs according to the original layout
 
Debugging:
   -v     verbose (show commands and results as they are executed)
   -x     script debug (set -x)

   Options to help nail down which modified part causes booting to fail.
   Lower numbers override higher numbered options:
   -1     Use original piggy.gz+piggy_trailer
   -2     Use original piggy.gz
   -3     Use original piggy
   -4     Use original initramfs(_gz)+part3
   -5     Use original initramfs_cpio"
    exit $1
}


### Graphical display of the unpack process:
#
#  Each of the indented items on the same level is derived from the
#  single item one level higher.
#
#  zImage
# (split)
#   +---- decompression_code
#   +---- piggy.gz+piggy_trailer
#       (split)
#          +---- piggy.gz
#          |  (gunzip)
#          |      +---- piggy
#          |      ===== either (compressed initramfs) ====
#          |             |
#          |          (split via gunzip limits)
#          |             +---- kernel.img
#          |             +---- initramfs_gz+part3
#          |                  (split)
#          |                    +---- initramfs.cpio.gz
#          |                    |   (gunzip)
#          |                    |      +---- initramfs.cpio
#          |                    |           (cpio -i)
#          |                    |             +---- initramfs/
#          |                    +---- padding3
#          |                    +---- part3
#          |      ===== or (uncompressed initramfs) =====
#          |             |
#          |          (split at "0707")
#          |             +---- kernel.img
#          |             +---- initramfs+part3
#          |                  (split after "TRAILER!!!")
#          |                    +---- initramfs.cpio
#          |                    |    (cpio -i)
#          |                    |     +---- initramfs/
#          |                    +---- padding3
#          |                    +---- part3
#          +---- padding_piggy
#          +---- piggy_trailer
#
#

pname="${0##*/}"
args=("$@")
cur_dir="$(pwd)"

# file names:
decompression_code="decompression_code"
piggy_gz_piggy_trailer="piggy.gz+piggy_trailer"
piggy="piggy"
piggy_gz="piggy.gz"
padding_piggy="padding_piggy"
piggy_trailer="piggy_trailer"
ramfs_gz_part3="initramfs.cpio+part3"
ramfs_cpio_gz="initramfs.cpio.gz"
padding3="padding3"
part3="part3"
kernel_img="kernel.img"
ramfs_cpio="initramfs.cpio"
ramfs_dir="initramfs"
sizes="sizes"
ramfs_part3="ramfs+part3"
ramfs_list="initramfs_list"
cpio_t="cpio-t"


cpio="cpio_set0"

# We dup2 stderr to 3 so an error path is always available (even
# during commands where stderr is redirected to /dev/null).  If option
# -v is set, we dup2 sterr to 9 also so commands (and some of their
# results if redirected to &9) are printed also.
exec 9>/dev/null                # kill diagnostic ouput (will be >&2 if -v)
exec 3>&2                       # an always open error channel

#
########### Start of functions
#

# Emit an error message and abort
fatal(){
    # Syntax: fatal <string ...>
    # Output error message, then abort
    echo >&3
    echo >&3 "$pname: $*"
    kill $$
    exit 1
}

# Execute a command, displaying the command if -v:
cmd(){
    # Syntax: cmd <command> <args...>
    # Execute <command>, echo command line if -v
    echo >&9 "$*"
    "$@"
}

# Execute a required command, displaying the command if -v, abort on
# error:
rqd(){
    # Syntax: cmd <command> <args...>
    # Execute <command>, echo commandline if -v, abort on error
    cmd "$@" || fatal "$* failed."
}

relpath(){
    # Syntax: relpath <absolute_path>
    # Function: print a path below $cur_dir as relative path on stdout
    if [ "${1#$cur_dir}" != "$1" ]; then
        echo -n ".${1#$cur_dir}"
    else   # not below cur_dir
        echo -n "$1"
    fi
}

findByteSequence(){
    # Syntax: findByteSequence <fname> [<string, default: gzip header>]
    # Returns: position (offset) on stdout, empty string if nothing found
    file="$1"
    local opt
    if [ "$2" = "lzma" ]; then
        srch=$'\x5d....\xff\xff\xff\xff\xff'
        opt=
    else
        srch="${2:-$'\x1f\x8b\x08'}" # Default: search for gzip header
        opt="-F"
    fi
    pos=$(LC_ALL=C grep $opt -a --byte-offset -m 1 --only-matching -e "$srch" -- "$file")
    echo ${pos%%:*}
}

getFileSize(){
    # Syntax: getFileSize <file>
    # Returns size of the file on stdout.
    # Aborts if file doesn't exist.
    rqd stat -c %s "$1"
}

recordPackingFileSize()(
    # Syntax: recordPackingFileSize <file-var> ...
    #
    # dump out a file size from the packing directory for debugging.
    # Note that the whole function is running in a subshell, so we can
    # cd here.
    rqd cd "$packing"
    for file in "$@"; do
        eval local fnam=\$$file
        local size=$(getFileSize "$fnam")
        printf 'size_%s=%d	# %#x\n' $file $size $size  
    done >> "$sizes"
)

recordFileSize(){
    # Syntax: recordFileSize <file-var> ...
    # Dump a file size from the current directory into $sizes for
    # later sourcing as a shell script.
    for file in "$@"; do
        eval local fnam=\$$file
        local size=$(getFileSize "$fnam")
        printf 'size_%s=%d	# %#x\n' $file $size $size  
    done >> "$sizes"
}

recordVars(){
    # Syntax dumpVar <var-name>
    # Dumps var into file $sizes for later sourcing as a shell script
    for var in "$@"; do
        eval printf '"%s=\"%s\"\n"' $var \$$var \$$var  
    done >> "$sizes"
}

checkNUL(){
    # Syntax: checkNUL file offset
    # Returns true (0) if byte there is 0x0.
    [ "$(rqd 2>/dev/null dd if="$1" skip=$2 bs=1 count=1)" = $'\0' ]
}

# We can tell from the magic number where the start of a gzipped
# section is.  We cannot tell its exact end.  We could only know the
# end if we could get at the kernel's zeropage variables - which we
# can't since their position varies between versions and
# architectures.  The following function separates the gzipped part
# from trailing bytes (which can be possibly garbage, but who knows?)
# via successive aproximation.
gunzipWithTrailer(){
    # Syntax gunzipWithTrailer <file> <gzip name, sans .gz> <padding> <trailer>
    #
    # <file>: the input file 
    # <gzip name, sans .gz>, <padding>, <trailer>: 
    #   The output files.  For the gzipped part, both the
    #   compressed and the uncompressed output is generated, so we have
    #   4 output files.
    local file="$1"
    local gz_result="$2.gz"
    local result="$2"
    local padding="$3"
    local trailer="$4"
    local tmpfile="/tmp/gunzipWithTrailer.$$.gz"
    local original_size=$(getFileSize "$file")
    local d=$(( (original_size+1) / 2))
    local direction fini at_min=0
    local results_at_min=()
    local size=$d
    local at_min=
    echo "Separating gzipped part from trailer in '$(relpath "$file")'"
    echo -n "Trying size: $size"
    while :; do
        rqd dd if="$file" of="$tmpfile" bs=$size count=1 2>/dev/null
        cmd gunzip >/dev/null 2>&1 -c "$tmpfile"
        res=$?
        if [ "$d" -eq 1 ]; then
            : $((at_min++))
            results_at_min[$size]=1
            [ "$at_min" -gt 3 ] && break
        fi
        d=$(((d+1)/2))
        case $res in
                # 1: too small
            1) size=$((size+d)); direction="↑";;
                # 2: trailing garbage
            2) size=$((size-d)); direction="↓";;
                # OK
            0) break;;
            *) fatal "gunzip returned $res while checking '$(relpath "$file")'";;
        esac
        echo -n "  $size"
    done
    if [ 0"$at_min" -gt 3 ]; then
        echo -e "\ngunzip result is oscillating between 'too small' and 'too large' at size: ${!results_at_min[*]}"
        echo -n "Trying lower nearby values:  "
        fini=
        for ((d=1; d < 30; d++)); do
            : $((size--))
            echo -n "  $size"
            rqd dd if="$file" of="$tmpfile" bs=$size count=1 2>/dev/null
            if cmd gunzip >/dev/null 2>&1 -c "$tmpfile"; then
                echo -n " - OK"
                fini=1
                break
            fi
        done
        [ -z "$fini" ] && fatal 'oscillating gunzip result, giving up.'
    fi
    # We've found the end of the gzipped part.  This is not the real
    # end since gzip allows for some trailing padding to be appended
    # before it barfs.  First, go back until we find a non-null
    # character:
    echo -ne "\npadding check (may take some time): "
    real_end=$((size-1))
    while checkNUL "$file" $real_end; do
        : $((real_end--))
    done
    # Second, try if gunzip still succeeds.  If not, add trailing
    # null(s) until it succeeds:
    while :; do
        rqd dd if="$file" of="$tmpfile" bs=$real_end count=1 2>/dev/null
        gunzip >/dev/null 2>&1 -c "$tmpfile"
        case $? in
            # 1: too small
            1) : $((real_end++));;
            *) break;;
        esac
    done
    real_next_start=$size
    # Now, skip NULs forward until we reach a non-null byte.  This is
    # considered as being the start of the next part.
    while checkNUL "$file" $real_next_start; do
        : $((real_next_start++))
    done
    echo $((real_next_start - real_end))
    echo
    rm "$tmpfile"
    # Using the numbers we got so far, create the output files which
    # reflect the parts we've found so far:
    rqd dd 2>&9 if="$file" of="$gz_result" bs=$real_end count=1
    rqd dd 2>&9 if="$file" of="$padding" skip=$real_end bs=1 count=$((real_next_start - real_end))
    rqd dd 2>&9 if="$file" of="$trailer" bs=$real_next_start skip=1
    rqd gunzip -c "$gz_result" > "$result"
}

# See the comment for gunzipWithTrailer (above) for what this function
# does:
unlzmaWithTrailer(){
    # Syntax unlzmaWithTrailer <file> <gzip name, sans .gz> <padding> <trailer>
    #
    # <file>: the input file 
    # <gzip name, sans .gz>, <padding>, <trailer>: 
    #   The output files.  For the lzma'd part, both the
    #   compressed and the uncompressed output is generated, so we have
    #   4 output files.
    local file="$1"
    local gz_result="$2.gz"
    local result="$2"
    local padding="$3"
    local trailer="$4"
    local tmpfile="/tmp/unlzmaWithTrailer.$$.gz"
    local original_size=$(getFileSize "$file")
    local d=$(( (original_size+1) / 2))
    local direction fini at_min=0
    local results_at_min=()
    local size=$d
    local at_min=
    echo "Separating lzma'd part from trailer in '$(relpath "$file")'"
    echo -n "Trying size: $size"
    while :; do
        rqd dd if="$file" of="$tmpfile" bs=$size count=1 2>/dev/null
        cmd unlzma >/dev/null 2>&1 -S '' -c "$tmpfile"
        res=$?
        if [ "$d" -eq 1 ] && [ "$res" -eq 1 ]; then
            at_min=yes          # we're 1 below the result
        fi
        d=$(((d+1)/2))
        case $res in
                # 1: too small
            1) size=$((size+d)); direction="↑";;
                # 0: too large (or OK if d==1)
            0) if [ "$at_min" ]; then
                  break
               fi
               size=$((size-d)); direction="↓";;
            *) fatal "unlzma returned $res while checking '$(relpath "$file")'";;
        esac
        echo -n "  $size"
    done
    # Now, skip NULs forward until we reach a non-null byte.  This is
    # considered as being the start of the next part.
    echo
    echo -n "Detecting padding: "
    real_end="$size"
    real_next_start="$size"
    while checkNUL "$file" $real_next_start; do
        : $((real_next_start++))
    done
    echo $((real_next_start - real_end))
    echo
    rm "$tmpfile"
    # Using the numbers we got so far, create the output files which
    # reflect the parts we've found so far:
    rqd dd 2>&9 if="$file" of="$gz_result" bs=$real_end count=1
    rqd dd 2>&9 if="$file" of="$padding" skip=$real_end bs=1 count=$((real_next_start - real_end))
    rqd dd 2>&9 if="$file" of="$trailer" bs=$real_next_start skip=1
    rqd unlzma -c -S '' "$gz_result" > "$result"
}

padTo(){
    # Syntax: padTo <file> <size>
    # Pads <file> to <size> with trailung 0x0s
    # Does nothing if file matches size.
    # Aborts if <file> too large for the operation.
    local size=$(getFileSize "$1")
    local tmp="/tmp/$pname.$$.zeroes"
    if [ "$size" -eq "$2" ]; then
        echo  "$(relpath "$1"): size matches ($size)"
    elif [ "$size" -gt "$2" ]; then
        fatal "Size of '$(relpath "$1")' too large ($size > $2) (+$((size - $2)))"
    else
        echo "Padding '$(relpath "$1")' to $2 bytes (+$(($2 - size)))"
        rqd dd 2>&9 if=/dev/zero of="$tmp" count=1 bs=$(($2 - size))
        rqd cat "$tmp" >> "$1"
        rqd rm -f "$tmp"
    fi
}

padToMod(){
    # Syntax: padTo <modulo> <file>
    # Pads <file> until (size mod <modulo>) == 0.
    local modulo=$1
    local file="$2"
    local size=$(getFileSize "$file")
    local rest=$((size % modulo))
    if [ "$rest" -ne 0 ]; then
        padTo "$file" $((size + modulo - rest))
    fi
}

buildZImageTar(){
    # Syntax: buildZImageTar <path>
    # Generates tarred file from <path> into the same directory.
    # The file in the archive doesn't contain the path.
    # Also copies the result to /home/Shared if it detects
    # that it is running at home.
    local dir="${1%/*}"/
    [ "$dir" = "$1/" ]  && dir="$(pwd)/"
    (
        cd "$dir"
        rqd tar  cf zImage.tar zImage
    )
    echo "Generated file: '$(relpath "${dir}$zImage.tar")'"
    if [ "$HOSTNAME:$USER" = "Xelzbrot:hcz" ]; then
        cp "${dir}zImage.tar" /home/Shared
        echo "also copied to '/home/Shared'."
    fi
}

reorderInitramfsList(){
    # This is some black magic to get about the same compression
    # result as the original initramfs.cpio.  We reorder the files in
    # our initramfs (which is to be created) so that they appear in
    # the same order as in the original initramfs.
    #
    # Syntax: reorderInitramfsList <initramfs_list_file> <reordering_template_file>
    #
    # Reorders <initramfs_list_file> so that enries are in the order
    # given by <reordering_template_file> (which comes from cpio -t).
    # Files in <initramfs_list_file> but not in
    # <reordering_template_file> are moved in sorted order to the end.
    # Comments and empty lines are discarded.  The result is written
    # to <initramfs_list_file>.

    #echo >&2 "Reordering initramfs list"
    initramfs_list_file="$1"
    reordering_template_file="$2"
    declare -A ramfs_entries    # make it an associative array
    while read line; do
        set -- $line
        [ $# -eq 0 ] && continue # skip empty lines
        [[ "$1" = \#* ]] && continue # skip comments
        ramfs_entries["$2"]="$line"  # else remember line, indexed by path
    done < "$initramfs_list_file"
    echo "# reordered ramfs entries" > "$initramfs_list_file"
    # now spit the lines out in the order given by the reordering_template_file:
    while read path; do
        echo "${ramfs_entries["$path"]}"
        unset ramfs_entries["$path"] # remove written lines from the array
    done < "$reordering_template_file" >> "$initramfs_list_file"
    # if there are any files left, append them in sorted order so directories
    # come first:
    for line in "${ramfs_entries[@]}"; do
        echo "$line"
    done \
    | sort >> "$initramfs_list_file"
}

pack(){
    if ! find >/dev/null 2>&1 "$unpacked" "$unpacked/$ramfs" "$unpacked/$sizes" -maxdepth 0; then
        fatal "\
This does not look like a directory where a
previous unpack has been done."
    fi
      
    # create packing direcory
    rqd mkdir -p "$packing"

    sizes="$packing/sizes"
    echo "# Packing sizes" > "$sizes"

    # cd to unpacking directory (original and modified parts)
    rqd cd "$unpacked"
    # read in file size at the time of unpicking
    rqd source sizes

    if [ "$opt_1" ]; then
        rqd cp "$piggy_gz_piggy_trailer" "$packing"
    else
        if [ "$opt_2" ]; then
            rqd cp "$piggy_gz" "$packing"
        else
            if [ "$opt_3" ]; then
                rqd cp "$piggy" "$packing"
            else
                if [ "$opt_4" ]; then
                    rqd cp "$ramfs_gz_part3" "$packing"
                else
                    if [ "$opt_5" ]; then
                        rqd cp "$ramfs_cpio" "$packing"
                    else
                        echo "Generating initramfs"
                        if ! which >/dev/null "$cpio"; then
                            if [ -n "$compressed" ]; then
                                echo "Info: '$cpio' not found, using normal cpio."
                                echo " This only means that your compressed initramfs will be slightly larger"
                                echo " and its size will differ from invocation to invocation."
                            fi
                            cpio="cpio"
                        fi
                        for ftime in "" "-a" "-m"; do
                            find "$ramfs_dir" -exec touch $ftime -d @0 {} \;
                        done
                        rqd gen_initramfs_list.sh -u squash -g squash "$ramfs_dir" > "$packing/$ramfs_list"
                        cp "$packing/$ramfs_list" "$packing/$ramfs_list.orig"
                        if [ -z "$opt_r" ]; then
                            # reorder so files are arranged as in original initramfs:
                            reorderInitramfsList "$packing/$ramfs_list" "$cpio_t"
                        else
                            # sort so directories come before their content:
                            sort < "$cpio_t" > "$packing/$cpio_t.sorted"
                            reorderInitramfsList "$packing/$ramfs_list" "packing/$cpio_t.sorted"
                        fi
                        if [ -z "$opt_g" ]; then
                            # No -g:  Use our own cpio routine
                            (
                                rqd cd "$ramfs_dir"
                                # extract the file names from our
                                # (possibly reordered) initramfs list
                                # and pass them to cpio:
                                while read line; do
                                    set -- $line
                                    [ $# -eq 0 ] && continue # skip empty lines
                                    [[ "$1" = \#* ]] && continue # skip comments
                                    echo "${2#/}"
                                done < "$packing/$ramfs_list" \
                                | rqd "$cpio" -H newc -R root:root -o  > "$packing/$ramfs_cpio"
                            )
                        else
                            # -g set: use gen_init_cpio (from kernel tree)
                            rqd gen_init_cpio "$packing/$ramfs_list" > "$packing/$ramfs_cpio"
                        fi
                        recordPackingFileSize ramfs_cpio
                    fi  # opt_5
                    
                    if [ "$compressed" = "gz" ]; then
                        echo "Creating gzip compressed initramfs"
                        rqd gzip -8 < "$packing/$ramfs_cpio" > "$packing/$ramfs_cpio_gz"
                        padTo "$packing/$ramfs_cpio_gz" "$((size_ramfs_cpio_gz + size_padding3))"
                        rqd cat "$packing/$ramfs_cpio_gz" "$part3" > "$packing/$ramfs_gz_part3"
                        recordPackingFileSize ramfs_cpio_gz ramfs_gz_part3
                    elif [ "$compressed" = "lzma" ]; then
                        echo "Creating lzma compressed initramfs"
                        rqd lzma -9  < "$packing/$ramfs_cpio" > "$packing/$ramfs_cpio_gz"
                        padTo "$packing/$ramfs_cpio_gz" "$((size_ramfs_cpio_gz + size_padding3))"
                        rqd cat "$packing/$ramfs_cpio_gz" "$part3" > "$packing/$ramfs_gz_part3"
                        recordPackingFileSize ramfs_cpio_gz ramfs_gz_part3
                    else
                        echo "initramfs is not compressed"
                    fi
                fi  # opt_4

                echo "Assembling piggy"
                if [ -n "$compressed" ]; then
                    rqd cat "$kernel_img" "$packing/$ramfs_gz_part3" > "$packing/$piggy"
                    compress_list=("$packing/$piggy") # compress it as a single file
                else
                    #touch "$packing/$padding3"
                    #padTo "$packing/$padding3" "$size_padding3"
                    padTo "$packing/$ramfs_cpio" $((size_ramfs_cpio + size_padding3))
                    # compress parts seperately (yields better compression results):
                    cat  "$kernel_img" "$packing/$ramfs_cpio" "$part3" > "$packing/$piggy"
                    recordPackingFileSize "piggy"
                    compress_list=("$packing/$piggy")
                fi
            fi  # opt_3
            echo "Creating piggy.gz"
            target_size=$((size_piggy_gz + size_padding_piggy))
            # At first, use gzip -9 for compressing since it delivers
            # better results with zImages most of the time:            
            rqd gzip -n -9 -c  "${compress_list[@]}" > "$packing/$piggy_gz"
            size1=$(getFileSize "$packing/$piggy_gz")
            if [  "$size1" -gt "$target_size" ]; then
                # too large.  Try if we can get better results with
                # gzip -8.  If not, barf and abort:
                rqd gzip -8 -n -c "${compress_list[@]}" > "$packing/$piggy_gz"
                size2=$(getFileSize "$packing/$piggy_gz")
                if [  "$size2" -gt "$target_size" ]; then
                    fatal "\
piggy.gz too large (gzip -9: +$((size1-target_size)), gzip -8: +$((size2-target_size)))
You might want to try a different combination of the -g, -r and -s options."
                fi
            fi
            padTo "$packing/$piggy_gz" "$((size_piggy_gz + size_padding_piggy))"
            recordPackingFileSize "piggy_gz"
        fi  # opt_2
        echo "Assembling $zImage"
        rqd cat "$packing/$piggy_gz" "$piggy_trailer" > "$packing/$piggy_gz_piggy_trailer"
    fi   # opt_1
    rqd cat "$decompression_code" "$packing/$piggy_gz_piggy_trailer" \
        > "$packing/$zImage"
    echo "Successfully created '$(relpath "$packing/$zImage")'"
    recordPackingFileSize zImage
    buildZImageTar "$packing/$zImage"
}

unpack()(
    [ -d "$unpacked" ] && echo "\
Warning: there is aready an unpacking directory.  If you have files added on 
your own there, the  repacking result may not reflect the result of the 
current unpacking process."
    rqd mkdir -p "$unpacked"
    rqd cd "$unpacked"
    sizes="$unpacked/sizes"
    echo "# Unpacking sizes" > "$sizes"

    piggy_start=$(findByteSequence "$cur_dir/$zImage")
    if [ -z "$piggy_start" ]; then
        fatal "Can't find a gzip header in file '$zImage'"
    fi
    
    rqd dd 2>&9 if="$cur_dir/$zImage" bs="$piggy_start" count=1 of="$decompression_code"
    rqd dd 2>&9 if="$cur_dir/$zImage" bs="$piggy_start" skip=1 of="$piggy_gz_piggy_trailer"
    recordFileSize decompression_code piggy_gz_piggy_trailer

    gunzipWithTrailer  "$piggy_gz_piggy_trailer" \
        "$piggy" "$padding_piggy" "$piggy_trailer"

    recordFileSize "piggy" "piggy_gz" "padding_piggy" "piggy_trailer"

    ramfs_gz_start=$( findByteSequence "$piggy" lzma)
    if [ -n "$ramfs_gz_start" ]; then
        echo "Found lzma compressed ramdisk."
        compressed=lzma
    else
        ramfs_gz_start=$( findByteSequence "$piggy")
        if [ -n "$ramfs_gz_start" ]; then
            echo "Found gzip compressed ramdisk."
            compressed=gz
        fi
    fi
    if [ "$compressed" ]; then
        rqd dd 2>&9 if="$piggy" of="$kernel_img" bs="$ramfs_gz_start" count=1
        rqd dd 2>&9 if="$piggy" of="$ramfs_gz_part3" bs="$ramfs_gz_start" skip=1
        if [ "$compressed" = "gz" ]; then
            rqd gunzipWithTrailer "$ramfs_gz_part3" "$ramfs_cpio" "$padding3" "$part3"
        else
            rqd unlzmaWithTrailer "$ramfs_gz_part3" "$ramfs_cpio" "$padding3" "$part3"
        fi
        recordFileSize "kernel_img" "ramfs_cpio_gz" "padding3" "ramfs_gz_part3" "ramfs_cpio" "part3"
        recordVars compressed

    else
        echo "Found uncompressed ramdisk."
        compressed=""

        initrd_start=$(findByteSequence "$piggy" "0707")
        [ -z "$initrd_start" ] && fatal "Cannot find cpio header"
        rqd dd 2>&9 if="$piggy" of="$kernel_img" bs="$initrd_start" count=1
        rqd dd 2>&9 if="$piggy" of="$ramfs_part3" bs="$initrd_start" skip=1

        initrd_end=$(findByteSequence "$ramfs_part3" "TRAILER!!!")
        [ -z "$initrd_end" ] && fatal "Cannot find cpio trailer"
        initrd_end=$((initrd_end + 10)) # skip trailer length
        initrd_end=$(( (initrd_end | 0x1ff) + 1)) # round up to block size (512)
        rqd dd 2>&9 if="$ramfs_part3" of="$ramfs_cpio" bs="$initrd_end" count=1

        real_next_start=$initrd_end
        echo -n "Detecting padding (may take some time): "
        while checkNUL "$ramfs_part3" $real_next_start; do
            : $((real_next_start++))
        done
        padding3_len=$((real_next_start - initrd_end))
        echo $padding3_len
        rqd dd 2>&9 if="$ramfs_part3" of="$padding3" skip="$initrd_end" count="$padding3_len" bs=1 
        rqd dd 2>&9 if="$ramfs_part3" of="$part3" bs="$real_next_start" skip=1

        recordFileSize "kernel_img" "padding3" "ramfs_part3" "ramfs_cpio" "part3"
        recordVars compressed
    fi
    echo "Unpacking initramfs"
    rqd cpio -t < "$ramfs_cpio" > "$cpio_t"
    rqd mkdir -p "$ramfs_dir"
    (
        rqd cd "$ramfs_dir"
        rqd cpio -i -m --no-absolute-filenames -d -u < "../$ramfs_cpio"
    )
    echo
    echo "Success."
    echo "The unpacked files and the initramfs directory are in '$(relpath "$unpacked")'."
)

#### start of main program
while getopts xv12345sgrpuhtz-: argv; do
    case $argv in
        p|u|z|1|2|3|4|5|t|r|g) eval opt_$argv=1;;
        v) exec 9>&2; opt_v=1;;
        s) cpio="cpio";;
        x) set -x;;
        -) if [ "$OPTARG" = "version" ]; then
              echo "$pname $version"
              exit 0
           else
              usage
           fi;;
        h|-) usage;;
        *) fatal "Illegal option";;
    esac
done
shift $((OPTIND-1))
zImage="${1:-zImage}"
unpacked="$cur_dir/${zImage}_unpacked"
packing="$cur_dir/${zImage}_packing"
shift
if [ -n "$*" ]; then
    fatal "Excess arguments: '$*'"
fi

if [ -n "$opt_z" ]; then
    buildZImageTar "$zImage"
fi
if [ -n "$opt_u" ]; then
    [ -f "$zImage" ] || fatal "file '$zImage': not found"
    unpack
fi
if [ -n "$opt_p" ]; then
    pack
fi
#if [ -n "$opt_t" ]; then        # for testing
#    reorderInitramfsList "$packing/$ramfs_list" "$unpacked/$cpio_t"
#fi
if [ -z "$opt_p$opt_u$opt_z$opt_t" ]; then
    echo >&2 "$pname: Need at least one of -u, -p, or -z."
    echo >&2 "$pname: Type '$pname --help' for usage info."
    exit 1
fi

exit

