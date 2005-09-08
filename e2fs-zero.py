#!/usr/bin/env python
# Copyright Paul Sladen <code@paul.sladen.org>, 2005-05-14
# You may use this work under the terms of the GNU GPL.
#
# Synopsis:
# 1.  call dumpe2fs /dev/xxxx | grep -E '^(  Free blocks: |Block size:)'
# 2.  decode Block size, eg. 4096 bytes
# 3.  decode ranges of Free blocks, like:   123, 132-145, 149-150, 167
# 4.  open '/dev/xxxx' for writing
# 5.  seek to each location (block_number * block_size) and write lots of NUL
# 6.  profit

"""\
e2fszero 0.1 (2005-05-14)
Usage: e2fs-zero [-h] [-v] [-w|-n] ext2-filesystem
Zero unused blocks in an Ext2 Filesystem, to increase compression and rsyncability.
  -h --help      this message
  -v --verbose   extra information
  -n --dryrun    disable writing to the filesystem
  -w --write     enable writing to the filesystem (default)
Note: This program relies on 'dumpe2fs' to do the dangerous calculations!
NOTE: YES, THIS PROGRAM REALLY WILL OVERWRITE (bits of) YOUR FILESYSTEM WITH NULLS\
"""
DUMPE2FS = '/sbin/dumpe2fs'
import os, sys

# messages
verbose = False
# enable writing operations
dangerous = False

def main():
    global verbose, dangerous, DUMPE2FS

    # catch people who need usage help
    # this is the worst and more incorrect piece of code in here

    leftover = []
    for fight in sys.argv[1:]:
        if fight == '-v' or fight == '--verbose':
            verbose = True
            continue
        elif fight == '-n' or fight == '--dryrun':
            dangerous = False
            continue
        elif fight == '-w' or fight == '--write':
            dangerous = True
            continue
        elif fight[0] == '-':
            print __doc__
            sys.exit()
        leftover.append(fight)

    #print `leftover`

    try:
        if len(leftover) != 1:
            raise 'ArgumentError'
        filesystem = leftover[0]
        if len(filesystem) <= 0: 
            raise 'NoFilesystemName'
    except:
        print >> sys.stderr, __doc__
        sys.exit()

    # We need access to the filesystem image (either a block device or a very large file)
    # and we also need to have 'dumpe2fs', otherwise we can't open a pipe() from it.
    
    try:
        stat = os.stat(filesystem)
        stat = os.stat(DUMPE2FS)
        # Might aswell just let the user see any stderr errors from dumpe2fs,
        # although annoying it prints a banner first
        #out, err = os.popen3("%s '%s'" % (DUMPE2FS, filesystem))[1:]
        sys.stderr.write('calling ')
        pipe = os.popen("%s '%s'" % (DUMPE2FS, filesystem))
    except OSError:
        print >> sys.stderr, "$(PROGRAM): can't access $(filesystem), try --help"

    # We're looking for the following lines from dumpe2fs, in order, and ignoring the rest:
    #   Filesystem volume name:   <none>
    #   Free blocks:              134859
    #   Block size:               4096
    #     Free blocks:            1123, 1345-1456, 1567, 1678-1789
    #     Free blocks:            2123-2345, 2456-2567, 2678, 2789

    s = pipe.readline()
    if s <= 'Filesystem volume name:':
        raise "Failed to parse correct dumpe2fs output"

    # 'Free blocks:'
    while not s.startswith('Free blocks:') and len(s) > 0:
        s = pipe.readline()
    try: 
        free_blocks = int(s.strip().split(': ')[1])
    except:
        raise "Failed to parse unused block count ('Free blocks:')"
    if verbose:
        print "Detected filsystem contains %d free blocks" % (free_blocks)

    # 'Block size:'
    while not s.startswith('Block size:') and len(s) > 0:
        s = pipe.readline()
    try: 
        block_size = int(s.strip().split(': ')[1])
    except:
        raise "Failed to parse filesystem block-size ('Block size:')"
    if verbose:
        print "Detected filsystem block_size = %d bytes" % (block_size)

    # 'Free blocks:' (multiple entries, one per Ext2 "group")
    free_ranges = []
    while True:
        while len(s) and not s.startswith('  Free blocks:'):
            try:
                s = pipe.readline()
            except:
                raise "failed to read"
        # Detect EOF
        if not len(s):
            break
        #print len(s), `s`
        # Strip the label: and separate the commas
        try:
            #print `s.strip()`
            free_ranges += s.split(': ', 1)[1].strip().split(', ')[:]
        except:
            print >> sys.stderr, `s`
            raise "Failed to parse free_ranges ('  Free blocks:')"
        s = pipe.readline()
    #print `free_ranges`

    # Turn the strings into integer lists of useful free blocks
    # 'blocks' contains each free blocks and get _very_ big
    # 'wipes' contains [offset, length] pairs
    record_blocks = False
    record_wipes = True
    blocks = []
    wipes = []
    free_block_count = 0

    for egg in free_ranges:
        if len(egg) > 0:
            # Assuming this ext2 group has some spare space in it...
            try:
                # Find some ranges (Ranges are inclusive, eg.  172-184)
                if egg.find('-') > 0:
                    #blocks += range(*map(int, egg.split('-')))
                    a, b = egg.split('-')
                    if record_blocks: blocks += range(int(a), int(b) + 1)
                    if record_wipes: wipes.append([block_size * int(a), block_size * (int(b) - int(a) + 1)])
                    free_block_count += int(b) - int(a) + 1
                # But some are singular (eg.  '199') is just one free block on its own
                else:
                    if record_blocks: blocks += [int(egg)]
                    if record_wipes: wipes.append([block_size * int(egg), block_size])
                    free_block_count += 1
            except:
                # since we're nearly at the point of writing to the disk,
                # it probably better to just safely roll over and die
                print "Bzzzz on trying to decode " + `egg`
    blocks.sort()
    #print len(blocks), `blocks`
    if verbose:
        print len(wipes), 'offset/length pairs', `wipes`
    if verbose or free_blocks != free_block_count:
        print "Free blocks; parsed: %d, decoded: %d" % (free_blocks, free_block_count)
    if free_blocks != free_block_count:
        raise 'Decoded Free blocks do not match count in filesystem!'
    perform_wipe(filesystem, wipes)

WRITE_SIZE = 2**18
PADDING = '\0'

# fstream file-access [open/f.write/f.tell] seems to have some
# grave funnyiness that causes the file to be randomly truncated.
# Since I spent a good while tearing my hair out over this, I've
# changed it to just use the normal POSIX os.open/os.write/close

# Here we take the offset/length pairs decoded above, open the
# ext2 filesystem image and overwrite the unused areas.
# it would be handy to truncate areas (make them sparse) so that they
# don't actually take up space on disk to...

def perform_wipe(filename, wipes = [[0, 0]]):
    progress_counter = 0.0
    percentage = 100.0 / len(wipes)
    empty_space = PADDING * WRITE_SIZE

    #f = open(filename, 'w')
    if dangerous:
        mode = os.O_WRONLY|os.EX_CANTCREAT
    else:
        mode = os.O_RDONLY|os.EX_CANTCREAT
    fd = os.open(filename, mode)

    # Don't waste space on a tty, display a progress percentage instead.
    if sys.stdout.isatty():
        end = '\r'
    else:
        end = '\n'
    for offset, length in wipes:
        progress_counter += percentage
        sys.stdout.write("wiping position %16d for %16d bytes  (%5.1f%%)%s" %
                         (offset, length, progress_counter, end))
        #f.seek(offset)
        os.lseek(fd, offset, 0)
        #print 'currently at (before) ' + `f.tell()`
        #print 'currently at (before) ' + `os.tell(fd)`
        # only write 256kB at a time, since we can stick that in a buffer
        # and not have Python regenerate HUGE arrays each time
        if 1:
            while length >= WRITE_SIZE and length > 0:
                #f.write(empty_space)
                #length -= WRITE_SIZE
                if dangerous:
                    length -= os.write(fd, empty_space)
                else:
                    length -= WRITE_SIZE
        #f.write('\xaa' * length)
        #f.write('hello')
        if dangerous:
            os.write(fd, PADDING * length)
        #print 'currently at (after)  ' + `f.tell()`
        #print 'currently at (after)  ' + `os.tell(fd)`
    #f.close()
    os.close(fd)
    if sys.stdout.isatty():
        print
    if verbose:
        print 'All done!  Hopefully your filesystem is not toast.'

if __name__ == '__main__':
    main()

