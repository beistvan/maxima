$main_info = $ARGV[0];
$infofile_encoding = $ARGV[1];

binmode STDOUT, $infofile_encoding;

$unit_separator = "";

# ------------------------------------------------------------------
# PART 1. BUILD INDEX FOR @DEFFN AND @DEFVR ITEMS
# ------------------------------------------------------------------

# (1.1)  Build index tables.

# (1.1a) Scan the *.info-* files for unit separator characters;
#        those mark the start of each texinfo node.
#        Build a hash table which associates the node name with the filename
#        and byte offset (NOT character offset) of the unit separator.
#
#        Do NOT use the indirect table + tag table (generated by makeinfo),
#        because those tables give character offsets; we want byte offsets.
#        It is easier to construct a byte offset table by hand,
#        rather than attempting to fix up the character offsets.
#        (Which are strange anyway.)

open (FH, "<" . $infofile_encoding, $main_info);
read (FH, $stuff, -s FH);

while ($stuff =~ m/^($main_info-\d+): (\d+)/cgsm) {
    $filename = $1;
    push @info_filenames, $filename;

    open FH2, "<" . $infofile_encoding, $filename;
    read FH2, $stuff2, -s FH2;

    while ($stuff2 =~ m/\G.*?(?=\n$unit_separator)/cgsm) {
        $offset = pos $stuff2;

        if ($stuff2 =~ m/^File:.*?Node: (.*?),/csgm) {
            $node_name = $1;
            $last_node_name = $node_name;
        }

        $node_offset{$node_name} = [($filename, int($offset))];
    }

    close $FH2;
}

close FH;

# (1.1b) Read the info index, which gives the node name and number of lines offset
#        for each indexed item. 

# ASSUME THAT THE INFO INDEX IS THE LAST NODE.
# (GETTING THE NODE NAME FROM THE COMMAND LINE IS PROBLEMATIC.)
$index_node_name = $last_node_name;

($index_filename, $index_node_offset) = @{$node_offset{$index_node_name}};

open (FH, "<" . $infofile_encoding, $index_filename);
read (FH, $stuff, -s FH);

if ($stuff =~ m/^File:.*?Node: $index_node_name.*^\* Menu:/icgsm) {
    while ($stuff =~ m/\G.*?^\* (\S+|[^:]+):\s+(.*?)\.\s+\(line\s+(\d+)\)/cgsm) {
        $topic_name = $1;
        $node_name = $2;
        $lines_offset = $3;
        $topic_locator{$topic_name} = [($node_name, $lines_offset)];
    }
}

close FH;

# (1.2)  Translate node name and number of lines offset into file name and byte offset
#        for each indexed item.
#        Also find the length of each item.

foreach $key (sort keys %topic_locator) {
    ($node_name, $lines_offset) = @{$topic_locator{$key}};
    ($filename, $character_offset) = @{$node_offset{$node_name}};
    $byte_offset = seek_lines($filename, $character_offset, $lines_offset);

    open FH, "<" . $infofile_encoding, $filename;
    seek FH, $byte_offset, 0;
    read FH, $stuff, -s FH;
    if ($stuff =~ m/(.*?)(?:\n\n(?= -- )|\n(?=[0-9])|(?=$unit_separator))/cgsm) {
        $text_length = length $1;
    }
    else {
        # Eat everything up til end of file.
        $stuff =~ m/(.*)/cgsm;
        $text_length = length $1;
    }
    close FH;

    $topic_locator{$key} = [($node_name, $filename, $byte_offset, $text_length)];
}

# (1.3)  Generate Lisp code. The functions in info.lisp expect this stuff.

print "(in-package :cl-info)\n";
print "(defun cause-maxima-index-to-load () nil)\n";

#        Pairs of the form (<index topic> . (<filename> <byte offset> <length> <node name>))

print "(defvar *info-deffn-defvr-pairs* '(\n";
print "; CONTENT: (<INDEX TOPIC> . (<FILENAME> <BYTE OFFSET> <LENGTH IN CHARACTERS> <NODE NAME>))\n";

foreach $key (sort keys %topic_locator) {
    print "(\"$key\" . (\"$topic_locator{$key}[1]\" $topic_locator{$key}[2] $topic_locator{$key}[3] \"$topic_locator{$key}[0]\"))\n";
}

print "))\n";

# ------------------------------------------------------------------
# PART 2. BUILD INDEX FOR @NODE ITEMS
# ------------------------------------------------------------------

# (2.1)  Search for 'mmm.nnn' at the start of a line,
#        and take each one of those to be the start of a node.
#
#        We could use the node table ($node_offset here), but we don't.

#        (a) The node table indexes nodes which contain only menus.
#            We don't want those because they have no useful text.
#
#        (b) The offset stated in the node table tells the location
#            of the "File: ..." header. We would have to cut off that stuff.
#
#        (c) Offsets computed by makeinfo are character offsets,
#            so we would have to convert those to byte offsets.
#            (But we have to do that anyway, so I guess there's no
#            advantage either way on that point.)

for $filename (@info_filenames) {

    open (FH, "<" . $infofile_encoding, $filename);
    read (FH, $stuff, -s FH);

    while ($stuff =~ m/\G(.*?)(?=^\d+\.\d+ .*?\n)/cgsm) {

        # Since FH was opened with $infofile_encoding,
        # pos returns a CHARACTER offset.
        $begin_node_offset = pos($stuff);

        if ($stuff =~ m/((^\d+\.\d+) (.*?)\n)/cgsm) {
            $node_title = $3;
            $node_length = length $1;
        }

        # Node text ends at a unit separator character,
        # or at the end of the file.

        if ($stuff =~ m/\G(.*?)($unit_separator)/cgsm) {
            $node_length += length $1;
        }
        else {
            $stuff =~ m/\G(.*)/csgm;
            $node_length += length $1;
        }

        $node_locator{$node_title} = [($filename, $begin_node_offset, $node_length)];
    }

    close FH;
}

# Translate character offsets to byte offsets.

foreach $node_title (sort keys %node_locator) {
    ($filename, $begin_node_offset, $node_length) = @{$node_locator{$node_title}};
    open FH, "<" . $infofile_encoding, $filename;
    read FH, $stuff, $begin_node_offset;
    my $begin_node_offset_bytes = tell FH;
    close FH;

    $node_locator{$node_title} = [($filename, $begin_node_offset_bytes, $node_length)];
}

# (2.2)  Generate Lisp code.
#
#        Pairs of the form (<node name> . (<filename> <byte offset> <length>))

print "(defvar *info-section-pairs* '(\n";
print "; CONTENT: (<NODE NAME> . (<FILENAME> <BYTE OFFSET> <LENGTH IN CHARACTERS>))\n";

foreach $node_title (sort keys %node_locator) {
    ($filename, $begin_node_offset, $length) = @{$node_locator{$node_title}};
    print "(\"$node_title\" . (\"$filename\" $begin_node_offset ", $length, "))\n";
}

print "))\n";

#        Construct hashtables from the lists given above.

print "(load-info-hashtables)\n";

# ------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------

sub seek_lines {
    my ($filename, $character_offset, $lines_offset) = @_;
    open FH, "<" . $infofile_encoding, $filename;
    read FH, $stuff, $character_offset;

    # MAKEINFO BUG: LINE OFFSET IS LINE NUMBER OF LAST LINE IN FUNCTION DEFINITION
    # (BUT WE NEED THE FIRST LINE OF THE FUNCTION DEFINITION)
    # BUG IS PRESENT IN MAKEINFO 4.8; FOLLOWING CAN GO AWAY WHEN BUG IS FIXED
    
    for (1 .. $lines_offset + 1) {
        my $x_maybe = tell FH;
        my $line = <FH>;
        if ($line =~ /^ -- \S/) {
            $x = $x_maybe;
        }
    }

    # END OF MAKEINFO BUG WORKAROUND
    # WHEN WORKAROUND IS NO LONGER NEEDED, ENABLE THE FOLLOWING LINES:

    # <FH> for 1 .. $lines_offset;
    # $x = tell FH;

    close FH;
    return $x;
}
