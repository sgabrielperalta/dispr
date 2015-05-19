#!/usr/bin/env perl

#   dispr: Degenerate In-Silico PcR
#   Copyright (C) 2015  Douglas G. Scofield
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
#   Please submit bugs, comments and suggestions to:
#
#       https://github.com/douglasgscofield/dispr/issues
#
#   Douglas G. Scofield
#   Evolutionary Biology Centre, Uppsala University
#   Norbyvagen 18D
#   75236 Uppsala
#   SWEDEN
#   douglas.scofield@ebc.uu.se
#   douglasgscofield@gmail.com


use 5.18.4;  # needed for UPPMAX, this perl version compiled with threads

my $with_threads = eval 'use threads qw(stringify); 1';

# Allocate 536870912 bytes for the DFA tables 1 << 29.
# Trying 1 << 30 (1073741824 bytes) failed consistently.
# 134217728 1<< 27
my $with_RE2 = eval 'use re::engine::RE2 -max_mem => 1 << 29; 1';

use strict;
use warnings;

use Getopt::Long;
use Bio::Seq;
use Bio::SeqIO;
use Bio::Tools::IUPAC;
use Bio::Tools::SeqPattern;
#use Data::Dumper::Perltidy;

#"class1:F:CTNCAYVARCCYATGTAYYWYTTBYT"
#"class1:R:GTYYTNACHCYRTAVAYRATRGGRTT"

my @o_pf = qw/ class1:F:CTNCAYVARCCYATGTAYYWYTTBYT class2:F:CTNCANWCNCCHATGTAYTTYYTBCT /;
my @o_pr = qw/ class1:R:GTYYTNACHCYRTAVAYRATRGGRTT class2:R:TTYCTBARRSTRTARATNADRGGRTT /;
#my @o_pf = qw/ CTNCAYVARCCYATGTAYYWYTTBYT CTNCANWCNCCHATGTAYTTYYTBCT /;
#my @o_pr = qw/ GTYYTNACHCYRTAVAYRATRGGRTT TTYCTBARRSTRTARATNADRGGRTT /;
my $o_pi = 0;  # 1 - 1 = 0
#>class1|F
#CTNCAYVARCCYATGTAYYWYTTBYT
#>class1|R
#GTYYTNACHCYRTAVAYRATRGGRTT
#>class2|F
#CTNCANWCNCCHATGTAYTTYYTBCT
#>class2|R
#TTYCTBARRSTRTARATNADRGGRTT
my $o_primers;
my $o_multiplex = 0;
my $o_min = 1;
my $o_max = 2000;
my $o_maxmax = 10000;
my $o_focalsites;
my $o_focalbounds;
my ($o_focalbounds_up, $o_focalbounds_down) = (1000, 1000);
my $o_ref;
my $o_bed;
my $o_seq;
my $o_primerbed;
my $o_primerseq;
my $o_internalbed;
my $o_internalseq;
my $o_expand_dot = 0;
my $o_no_trunc = 0;
my $o_overlap = 0;
my $o_optimise = 0;
my $o_verbose;
my $o_debug_match = 0;
my $o_debug_mismatch = 0;
my $o_debug_optimise = 0;
my $o_debug_focal = 0;
my $o_help;
my $o_threads = 0;# 4;
my $o_threads_max = 4;

my $o_mismatch_simple;
my $o_mm_int1;  # number of mismatches
my $o_mm_int1_max = 5;
my $o_mm_int2;  # length of 5' sequence to apply mismatches
my $o_mm_int2_max = 10;
my $o_mm_int3;  # number of mismatches in remainder of primer
my $o_mm_int3_max = 2;
my $o_showmismatches = 0;
my $o_skip_count = 0;

my $tag;

my $short_usage = "
NOTE: '$0 --help' will provide more details.

USAGE:   $0  [ OPTIONS ] --ref fasta-file.fa

Applies forward and reverse primer pairs to the reference file,
identifying amplicons within given dimensions.

Primer and search parameters:
    --pf FORWARD_PRIMER      --pr REVERSE_PRIMER    [ --pi INT ]
    --primers FILE
    --mismatch-simple INT1:INT2[:INT3]              --skip-count
    --show-mismatches
    --focal-sites BED        --focal-bounds INT1[:INT2]
    --overlap

Amplicons:
    --multiplex              --no-multiplex
    --min bp                 --max bp               --maxmax bp

Input and output files:
    --ref INPUT_FASTA | INPUT_FASTA.gz | INPUT_FASTA.bz2

    --bed OUTPUT_BED         --seq OUTPUT_FASTA
    --primer-bed BED         --primer-seq FASTA
    --internal-bed BED       --internal-seq FASTA

Misc:
    --expand-dot             --verbose              --help
    --no-trunc               --threads [2 | 4]      --optimise
";

my $usage = "
$0  [ OPTIONS ] --ref fasta.fa

Applies forward and reverse primer pairs to the reference file, identifying
amplicons within given dimensions.  The primer sequences are sought paired in
specified orientations within a range given by --min and --max.  Sequence hits
are made without regard to case in the reference sequence; a hit to 'ACTG' is
equivalent to a hit to 'actg'.  'N' in the reference sequence will only hit a
site that also allows 'N'.

Duplicate primer sequence hits are removed, with the first hit in native
orientation (forward and reverse primers) having priority over later hits in
the same orientation as well as hits with either primer in reverse-complement.

The amplicon is measured from the outer extent of each primer sequence, so
includes the primer sequences.  Interior hits produced with --interior-bed and
--interior-seq are amplicon sequences with the primer sequences excluded.

Output to both BED and Fasta files includes the hit coordinates, the tag value,
and the orientation of the primer which produced the primer hit or the primer
pair which produced the amplicon/interior hit.  In the output, F and R indicate
forward and reverse primers in their given orientations, while f and r indicate
these primers in their reverse-complement orientations.  'F,R' indicates a hit
on the + strand while 'r,f' indicates a hit on the - strand.

Primer and search parameters:

    --pf FORWARD_PRIMER   Forward primer sequence (may be specified 1+ times)
    --pr REVERSE_PRIMER   Reverse primer sequence (may be specified 1+ times)
                          For --pf and --pr, primers must be specified using
                          the formats
                              tag:F:CCYATGTAYY   and   tag:R:CTBARRSTG
                          for the forward and reverse primers, respectively,
                          with valid IUPAC-coded sequence following the second
                          colon.  The tag is used to mark hits involving the
                          primer.  Tags may be unique to each primer, or may
                          be shared by at most one forward-reverse pair.
    --pi INT              Index of preloaded primer [default $o_pi]
         1: class 1 f $o_pf[0]  r $o_pr[0]
         2: class 2 f $o_pf[1]  r $o_pr[1]
                          This option will be removed prior to production
                          release.
    --primers FILE        Fasta-format file containing primer sequences.  Each
                          primer sequence must have a name of the format
                              >tag:F       or   >tag:R
                              CCYATGTAYY        CTBARRSTG
                          indicating forward and reverse primers, respectively.
                          Similar allowances for specification of primers apply
                          here as for the --pf/--pr options.

Primers may be specified using only one of --pf/--pr, --pi or --primers.

    --mismatch-simple INT1:INT2[:INT3]
                          Allow up to INT1 mismatches in 5'-most INT2 bp of
                          each primer, with optionally INT3 mismatches in the
                          remainder of the primer.  INT1 must be <= $o_mm_int1_max,
                          INT2 must be <= $o_mm_int2_max, and INT3 must be <= $o_mm_int3_max.
                          For example, to allow up to 2 mismatches in the
                          5'-most 8 bp, with one mismatch in the remainder:
                              --mismatch-simple 2:8:1

    --show-mismatches     Include information on the number of mismatches for
                          each primer hit.  A mismatch is counted if it is
                          not matched by one possible base expressed in the
                          original degenerate sequence.  Information is
                          provided in the form
                              mism:4:13:1011000001000
                          where 4 is the total number of mismatches, 13 is the
                          match length, and 1011000001000 is a
                          position-by-position indication of whether a mismatch
                          occurred at that position.  If there are no
                          mismatches identified for the primer hit, then the
                          string for this example would be 'mism:0:13:0'.

    --overlap             Allow primer hits to overlap.  By default primer hits
                          for the same primer sequence in the same strand
                          direction do not overlap, and the hit reported where
                          two or more potential hits overlap is the 5'-most.
                          Amplicons may overlap if produced by non-overlapping
                          primer hits.  This also applies to matches found with
                          the --focal-sites and --optimise options.

    --skip-count          Skip counting the number of concrete primers that
                          match the degenerate primer after applying the
                          --mismatch-simple criteria.  This can require a few
                          minutes and a moderate amount of memory if many
                          mismatches are allowed.  If this option is used, the
                          count is reported as -1.

    --focal-sites BED     Focus search for matches on regions surrounding sites
                          presented in BED, see also --focal-bounds.  Note that
                          --optimise and --threads cannot be specified when
                          using this option.
    --focal-bounds INT1[:INT2]
                          Relative to sites given in --focal-sites, scan
                          upstream of the 5' extent INT1 bp and downstream of
                          the 3' extent INT2 bp.  Both values must be positive
                          integers.  If INT2 is not provided, its value is
                          taken from INT1.  Positive values extend the region
                          up- and downstream, while negative values restrict
                          it.  [defaults $o_focalbounds_up:$o_focalbounds_down]

Amplicons:

    --multiplex           If more than one primer pair presented, consider
                          amplicons produced by any possible primer pair
                          (DEFAULT, BUT >1 PRIMER PAIR NOT CURRENTLY SUPPORTED)
    --no-multiplex        If more than one primer pair presented, only consider
                          amplicons produced by each primer pair
    --min bp              Minimum accepted size of amplicon [default $o_min]
    --max bp              Maximum accepted size of amplicon [default $o_max]
    --maxmax bp           Maximum 'too-long' amplicon to track [default $o_maxmax]

Input and output files:

    --ref INPUT_FASTA     Input, Fasta reference sequence in which to find
                          amplicons.  If the filename ends with '.gz', it is
                          opened as a Gzipped file.  If the filename ends with
                          '.bz2' it is opened as a Bzip2-compressed file.

    --bed OUTPUT_BED      Output, BED file containing identified amplicon
                          positions
    --seq OUTPUT_FASTA    Output, Fasta sequences containing identified
                          amplicon sequences
    --primer-bed BED      Output, BED file containing hits for primer
                          sequences found
    --primer-seq FASTA    Output, Fasta sequences containing identified
                          primer sequences
    --internal-bed BED    Output, BED file containing internal regions of
                          amplicon positions, which exclude primers
    --internal-seq FASTA  Output, Fasta sequences containing internal regions
                          of identified amplicon sequences, which exclude
                          primers

Misc:

    --optimise            Optimise pattern searching by looking first for the
                          tail, which typically supports fewer mismatches, then
                          for the head adjacent to each tail candidate found.
                          --optimize is a synonym.  This option cannot be used
                          when restricting the search via --focal-sites.

Note that with --optimise, the search is optimised for increased speed by first
searching for hits against the (presumably) lower-mismatch 3' tail section, and
then only searching for hits against the (presumably) higher-mismatch 5' head
section once a possible tail hit is found.  Note 'presumably'; searches which
allow for greater mismatches, either in the original degenerate sequence or
when specified with --mismatch-simple, require more time.  If your mismatch
profile does not fit the assumptions stated here, then --optimise might not be
helpful.

    --threads INT         Use 2 or 4 threads to search for hits in parallel
                          (default $o_threads, max $o_threads_max).  Threads
                          cannot be used when restricting the search via
                          --focal-sites.

    --expand-dot          Expand '.' in regexs to '[ACGTN]'.  With a
                          guaranteed DNA alphabet, this is not likely to be
                          helpful and might slow down pattern matching.
    --no-trunc            Do not truncate regexs when displaying
    --verbose             Describe actions

    --help/-h/-?          Produce this longer help

";

die $short_usage if not @ARGV;

GetOptions("pf=s"              => \@o_pf,
           "pr=s"              => \@o_pr,
           "pi=i"              => \$o_pi,
           "primers=s"         => \$o_primers,
           "mismatch-simple=s" => \$o_mismatch_simple,
           "show-mismatches"   => \$o_showmismatches,
           "overlap"           => \$o_overlap,
           "skip-count"        => \$o_skip_count,
           "focal-sites=s"     => \$o_focalsites,
           "focal-bounds=s"    => \$o_focalbounds,
           "primer-bed=s"      => \$o_primerbed,
           "primer-seq=s"      => \$o_primerseq,
           "internal-bed=s"    => \$o_internalbed,
           "internal-seq=s"    => \$o_internalseq,
           "multiplex"         => \$o_multiplex,
           "no-multiplex"      => sub { $o_multiplex = 0 },
           "min=i"             => \$o_min,
           "max=i"             => \$o_max,
           "maxmax=i"          => \$o_maxmax,
           "ref=s"             => \$o_ref,
           "bed=s"             => \$o_bed,
           "seq=s"             => \$o_seq,
           "optimise|optimize" => \$o_optimise,
           "threads=i"         => \$o_threads,
           "expand-dot"        => \$o_expand_dot,
           "no-trunc"          => \$o_no_trunc,
           "verbose"           => \$o_verbose,
           "debug-match"       => \$o_debug_match,
           "debug-mismatch"    => \$o_debug_mismatch,
           "debug-optimise"    => \$o_debug_optimise,
           "debug-focal"       => \$o_debug_focal,
           "help|h|?"          => \$o_help) or die $short_usage;
die $usage if $o_help;
#die "only one primer pair currently supported" if @o_pf > 1 or @o_pr > 1;
die "must provide sequence to search with --ref" if not $o_ref;


## re::engine::RE2 regexp engine
print STDERR "Found 're::engine::RE2'\n" if $with_RE2 and $o_verbose;
print STDERR "Did not find 're::engine::RE2'\n" if not $with_RE2 and $o_verbose;


## --mismatch-simple option processing
if ($o_mismatch_simple) {
    ($o_mm_int1, $o_mm_int2, $o_mm_int3) = split(/:/, $o_mismatch_simple, 3);
    $o_mm_int3 = 0 if not defined $o_mm_int3;
    die "unable to interpret --mismatch-simple argument" if not $o_mm_int1 or not $o_mm_int2;
    die "must allow 1 to $o_mm_int1_max mismatches in 5' end" if $o_mm_int1 < 1 or $o_mm_int1 > $o_mm_int1_max;
    die "must span 1 to $o_mm_int2_max 5' bases" if $o_mm_int2 < 1 or $o_mm_int2 > $o_mm_int2_max;
    die "must allow 0 to $o_mm_int3_max mismatches in remainder" if $o_mm_int3 < 0 or $o_mm_int3 > $o_mm_int3_max;
    print STDERR "Counting concrete primers may take a long time, consider --skip-count\n" if not $o_skip_count and $o_mm_int1 >= 4 and $o_mm_int2 >= 8;

} elsif ($o_showmismatches) {

    print STDERR "\nNOTE: --show-mismatches makes no sense without --mismatch-simple, unsetting\n";
    $o_showmismatches = 0;
}

# For --show-mismatches, create hash of hashes for each base code, for
# existence checks
#
my %iub = Bio::Tools::IUPAC->new->iupac_iub;
my %iupac;
foreach my $k (sort keys %iub) {
    foreach my $b (@{$iub{$k}}) {
        $k = uc($k);
        $b = uc($b);
        $iupac{$k}{$b}++;
    }
}

## --focal-bounds option processing
if ($o_focalsites) {
    # these restrictions are to make the source code simpler, plus their
    # speedups are probably not that important if we are using focal sites
    die "--optimise may not be used with --focal-sites" if $o_optimise;
    die "--threads may not be used with --focal-sites" if $o_threads;
    ($o_focalbounds_up, $o_focalbounds_down) = split(/:/, $o_focalbounds, 2) if $o_focalbounds;
    $o_focalbounds_down = $o_focalbounds_up if not defined $o_focalbounds_down;
}


## Threads
print STDERR "with_threads = $with_threads\n" if $o_verbose;
print STDERR "OSNAME = ".$^O."\n" if $o_verbose;
die "sorry, for some reason threads not possible" if $o_threads and not $with_threads;
die "must specify 0, 2 or $o_threads_max threads, not $o_threads" if $o_threads and $o_threads != 2 and $o_threads != $o_threads_max;
$with_threads = $o_threads = 0 if $o_threads <= 1;


sub expand_dot($);  # expand '.' in DNA regex
sub prepare_primer($);  # prepare primer for searches
sub create_mismatch($$$$);  # create mismatch sequences from degenerate sequence
sub apply_mismatch_simple($$$$);  # prepare query sequence for mismatches
sub count_head_tail($$);  # count number of sequences with mismatches
sub show_mismatches($$);  # count the number of mismatches in each of $1 vs. $2
sub show_mismatches2($$);  # count the number of mismatches in $1 vs. $2, return mismatch string
sub match_positions($$$);  # search for primer hits
sub match_positions_focal($$$$);  # search for primer hits in focal regions
sub match_positions_optimise($$$$$$$);  # search for head and tail of primer hits separately
sub remove_duplicate_intervals($);  # remove intervals with duplicate beg, end
sub dump_primer_hits($$$);  # dump primer-only intervals
sub dump_amplicon_internal_hits($$$);  # calculate and dump amplicons and internal hits

sub iftag  { return $tag ? "$tag:"  : ""; }
sub iftags { return $tag ? "$tag: " : " "; }
sub trunc($) {
    my $s = shift;
    return $s if $o_no_trunc;
    my $lim = 50;
    return length($s) > $lim ? substr($s, 0, $lim - 11)."<truncated>" : $s;
}

print STDERR "Please see the caution available via '$0 --help' regarding --optimise.\n\n" if $o_optimise;

sub diefile($) { my $f = shift; die "could not open '$f' :$!"; }


#----- load primers

my $forward_primer;
my $reverse_primer;

if ($o_pi) {
    my ($ptag, $pdir, $pseq) = split(/:/, $o_pf[$o_pi - 1], 3);
    $tag = $ptag;
    die "Forward primer direction not one of F, f: '$pdir'" if uc($pdir) ne "F";
    $forward_primer = $pseq;
    ($ptag, $pdir, $pseq) = split(/:/, $o_pr[$o_pi - 1], 3);
    die "Primer tags do not match: '$tag', '$ptag'" if $tag ne $ptag;
    die "Reverse primer direction not one of R, r: '$pdir'" if uc($pdir) ne "R";
    $reverse_primer = $pseq;
    print STDERR "Loaded predefined forward and reverse primers from index $o_pi, with tag '$tag'\n";
} elsif ($o_primers) {
    my $pfile = Bio::SeqIO->new(-file => "<$o_primers", -format => 'fasta') or diefile($o_primers);
    while (my $pseq = $pfile->next_seq()) {
        my $pid = $pseq->display_id();
        my ($ptag, $pdir) = split(/:/, $pid, 2);
        die "Primer direction not one of F, R, f, r: '$pdir'" if $pdir !~ /^[FR]$/i;
        if (! $forward_primer and uc($pdir) eq "F") {
            $forward_primer = $pseq->seq();
            if (! $tag) {
                $tag = $ptag;
            } else {
                die "Primer tags do not match: '$tag', '$ptag'" if $tag ne $ptag;
            }
        } elsif (! $reverse_primer and uc($pdir) eq "R") {
            $reverse_primer = $pseq->seq();
            if (! $tag) {
                $tag = $ptag;
            } else {
                die "Primer tags do not match: '$tag', '$ptag'" if $tag ne $ptag;
            }
        } else {
            die "$o_primers must contain one forward and one reverse primer sequence";
        }
    }
    print STDERR "Loaded forward and reverse primers from file '$o_primers', with tag '$tag'\n";
} else {
    die "No primer pair specified (--pf and --pr options not yet completed)";
}
die "Must provide results tag" if not $tag;

my %forward;
my %reverse;

if ($with_threads) {  # we have at least 2 threads
    my $forward_t = threads->create({'context' => 'list'}, \&prepare_primer, $forward_primer);
    my $reverse_t = threads->create({'context' => 'list'}, \&prepare_primer, $reverse_primer);
    print STDERR "Preparing forward and reverse primers with threads $forward_t and $reverse_t ...\n" if $o_verbose;
    %forward = $forward_t->join();
    %reverse = $reverse_t->join();
} else {
    %forward = prepare_primer($forward_primer);
    %reverse = prepare_primer($reverse_primer);
}


print STDERR "
Primer sequences as given:

".iftags()."forward primer : $forward_primer, ".length($forward_primer)." bp
".iftags()."reverse primer : $reverse_primer, ".length($reverse_primer)." bp

Patterns matching unrolled primers";
if ($o_mismatch_simple) {
    print STDERR " after applying '--mismatch-simple $o_mismatch_simple'";
}
print STDERR ":

".iftags()."forward   : ".trunc($forward{forwardpattern}).", $forward{count} unique sequences
".iftags()."forward rc: ".trunc($forward{revcomppattern}).", same number in reverse complement
".iftags()."reverse   : ".trunc($reverse{forwardpattern}).", $reverse{count} unique sequences
".iftags()."reverse rc: ".trunc($reverse{revcomppattern}).", same number in reverse complement
";

print STDERR "\nPrimer hits can overlap.\n" if $o_overlap;

print STDERR qq{
Assuming the following forward-reverse primer pair orientation:

    Forward:F:ACGTCT
    Reverse:R:TTACGC

        Forward>
    ----ACGTCT--------------GCGTAA-------
    ----TGCAGA--------------CGCATT-------
                          <esreveR

Amplicons are identified by being delimited by Forward-esreveR primer pairs,
one in forward orientation, the other in reverse-complement orientation.  Note
that together with their reverse-complements, these primers can delimit
amplicons three additional ways: Reverse-drawroF, Forward-draworF and
Reverse-esreveR.  All of these possibilities are reported here.  Amplicons
matched by primers in their given orientations as above are marked 'F,R', those
matched by primers in their reverse-complement orientations are marked 'r,f',
with the other possibilities marked 'F,f' and 'r,R', respectively.

} if $o_verbose;

print STDERR qq{
Minimum amplicon length: $o_min bp
Maximum amplicon length: $o_max bp

The maximum distance tracked between suitable primer pairs is $o_maxmax bp.
Primer pairs separated by up to this distance are counted and this count
is reported, but amplicons are not generated from them in the output.

};

my %focalsites;
my $n_focalsites;

if ($o_focalsites) {

    print STDERR qq{
The search is confined to focal sites as indicated by regions from the
BED file '$o_focalsites'.

Search boundary upstream from 5' end of regions:   $o_focalbounds_up bp
Search boundary downstream from 3' end of regions: $o_focalbounds_down bp

};

    #
    # Fill %focalsites hash with an array of sorted valid focal regions for each sequence
    #
    my $fbed;
    my $flen = 0;
    open($fbed, "<$o_focalsites") or diefile($o_focalsites);
    while (<$fbed>) {
        chomp;
        my ($s, $l, $r, $x) = split(/\t/, $_, 4);
        if ($l < 0 or $r < 0 or $l >= $r) {
            print STDERR "invalid bed interval: $s\t$l\t$r, skipping";
            next;
        }
        # check realised bounds of interval
        my ($left, $right) = ( $l - $o_focalbounds_up, $r + $o_focalbounds_down );
        if ($left >= $right - 1) {
            print STDERR "focal site '$s $l $r' unsearchable after applying bounds [$left, $right), skipping\n";
            next;
        }
        $focalsites{$s} = () if not exists $focalsites{$s};
        $flen += $r - $l;
        push @{$focalsites{$s}}, [ $l, $r ];  # stick with BED coordinates
        ++$n_focalsites;
    }
    die "no valid focal sites identified" if ! %focalsites;
    foreach my $k (sort keys %focalsites) {
        @{$focalsites{$k}} = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @{$focalsites{$k}};
    }
    print STDERR "$n_focalsites focal sites to be searched totalling $flen bp (without extended bounds) on ".scalar(keys(%focalsites))." separate sequences\n\n";
}




my $do_amplicon = ($o_bed or $o_seq);
my $do_primer = ($o_primerbed or $o_primerseq);
my $do_internal = ($o_internalbed or $o_internalseq);

print STDERR "WARNING: no Fasta or BED output will be produced.\n" if not $do_amplicon and not $do_primer and not $do_internal;

# open input, create output
my ($in,
    $out_seq, $out_bed,
    $out_primerseq, $out_primerbed,
    $out_internalseq, $out_internalbed);

if ($o_ref =~ /\.gz$/) {
    open (my $z, "gzip -dc $o_ref |") or diefile($o_ref);
    $in = Bio::SeqIO->new(-fh => $z, -format => 'fasta') or diefile($o_ref);
} elsif ($o_ref =~ /\.bz2$/) {
    open (my $z, "bzip2 -dc $o_ref |") or diefile($o_ref);
    $in = Bio::SeqIO->new(-fh => $z, -format => 'fasta') or diefile($o_ref);
} else {
    $in = Bio::SeqIO->new(-file => "<$o_ref", -format => 'fasta') or diefile($o_ref);
}

if ($o_seq) {
    $out_seq = Bio::SeqIO->new(-file => ">$o_seq", -format => 'fasta') or diefile($o_ref);
}
if ($o_bed) {
    open($out_bed, ">$o_bed") or diefile($o_ref);
}
if ($o_primerseq) {
    $out_primerseq = Bio::SeqIO->new(-file => ">$o_primerseq", -format => 'fasta') or diefile($o_ref);
}
if ($o_primerbed) {
    open($out_primerbed, ">$o_primerbed") or diefile($o_ref);
}
if ($o_internalseq) {
    $out_internalseq = Bio::SeqIO->new(-file => ">$o_internalseq", -format => 'fasta') or diefile($o_ref);
}
if ($o_internalbed) {
    open($out_internalbed, ">$o_internalbed") or diefile($o_ref);
}

my $Un;

while (my $inseq = $in->next_seq()) {
    my $this_seqname = $inseq->display_id();
    my $this_sequence = $inseq->seq();
    if ($this_seqname =~ /^chrUn/) {
        print STDERR "chrUn*:".iftag()." searching ...\n" if not $Un;
        ++$Un;
    } else {
        print STDERR "$this_seqname:".iftag()." searching ...\n";
    }

    # Any _forward_hits can be complemented by any _revcomp_hits

    my @f_forward_hits;
    my @r_revcomp_hits;
    my @r_forward_hits;
    my @f_revcomp_hits;

    if ($o_threads == 4) {

        my ($f_forward_t, $r_revcomp_t, $r_forward_t, $f_revcomp_t);

        if ($o_optimise) {
            $f_forward_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $forward{forwardheadquoted}, $forward{forwardtailquoted},
                $forward{headlen}, $forward{taillen}, 0, $inseq, "F");
            $r_revcomp_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $reverse{revcompheadquoted}, $reverse{revcomptailquoted},
                $reverse{headlen}, $reverse{taillen}, 0, $inseq, "R");
            $r_forward_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $reverse{forwardheadquoted}, $reverse{forwardtailquoted},
                $reverse{headlen}, $reverse{taillen}, 0, $inseq, "r");
            $f_revcomp_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $forward{revcompheadquoted}, $forward{revcomptailquoted},
                $forward{headlen}, $forward{taillen}, 0, $inseq, "f");
            print STDERR "Matching F, R, r and f primers optimised with threads $f_forward_t, $r_revcomp_t, $r_forward_t and $f_revcomp_t ...\n";# if $o_verbose;
        } else {
            $f_forward_t = threads->create({'context' => 'list'},
                \&match_positions, $forward{forwardquoted}, $inseq, "F");
            $r_revcomp_t = threads->create({'context' => 'list'},
                \&match_positions, $reverse{revcompquoted}, $inseq, "R");
            $r_forward_t = threads->create({'context' => 'list'},
                \&match_positions, $reverse{forwardquoted}, $inseq, "r");
            $f_revcomp_t = threads->create({'context' => 'list'},
                \&match_positions, $forward{revcompquoted}, $inseq, "f");
            print STDERR "Matching F, R, r and f primers with threads $f_forward_t, $r_revcomp_t, $r_forward_t and $f_revcomp_t ...\n";# if $o_verbose;
        }

        @f_forward_hits = $f_forward_t->join();
        @r_revcomp_hits = $r_revcomp_t->join();
        @r_forward_hits = $r_forward_t->join();
        @f_revcomp_hits = $f_revcomp_t->join();

    } elsif ($o_threads == 2) {

        my ($f_forward_t, $r_revcomp_t, $r_forward_t, $f_revcomp_t);

        if ($o_optimise) {
            $f_forward_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $forward{forwardheadquoted}, $forward{forwardtailquoted},
                $forward{headlen}, $forward{taillen}, 0, $inseq, "F");
            $r_revcomp_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $reverse{revcompheadquoted}, $reverse{revcomptailquoted},
                $reverse{headlen}, $reverse{taillen}, 0, $inseq, "R");
            print STDERR "Matching F and R primers optimised with thread $f_forward_t and $r_revcomp_t ...\n";# if $o_verbose;
        } else {
            $f_forward_t = threads->create({'context' => 'list'},
                \&match_positions, $forward{forwardquoted}, $inseq, "F");
            $r_revcomp_t = threads->create({'context' => 'list'},
                \&match_positions, $reverse{revcompquoted}, $inseq, "R");
            print STDERR "Matching F and R primers with thread $f_forward_t and $r_revcomp_t ...\n";# if $o_verbose;
        }

        @f_forward_hits = $f_forward_t->join();
        @r_revcomp_hits = $r_revcomp_t->join();

        if ($o_optimise) {
            $r_forward_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $reverse{forwardheadquoted}, $reverse{forwardtailquoted},
                $reverse{headlen}, $reverse{taillen}, 0, $inseq, "r");
            $f_revcomp_t = threads->create({'context' => 'list'}, \&match_positions_optimise,
                $forward{revcompheadquoted}, $forward{revcomptailquoted},
                $forward{headlen}, $forward{taillen}, 0, $inseq, "f");
            print STDERR "Matching r and f primers optimised with thread $r_forward_t and $f_revcomp_t ...\n"; # if $o_verbose;
        } else {
            $r_forward_t = threads->create({'context' => 'list'},
                \&match_positions, $reverse{forwardquoted}, $inseq, "r");
            $f_revcomp_t = threads->create({'context' => 'list'},
                \&match_positions, $forward{revcompquoted}, $inseq, "f");
            print STDERR "Matching r and f primers with thread $r_forward_t and $f_revcomp_t ...\n"; # if $o_verbose;
        }

        @r_forward_hits = $r_forward_t->join();
        @f_revcomp_hits = $f_revcomp_t->join();

    } else {

        if ($o_optimise) {

            print STDERR "Matching F, R, r and f primers optimised, sequentially ...\n"; # if $o_verbose;
            @f_forward_hits = match_positions_optimise($forward{forwardheadquoted},
                $forward{forwardtailquoted}, $forward{headlen}, $forward{taillen}, 0,
                $inseq, "F");
            @r_revcomp_hits = match_positions_optimise($reverse{revcompheadquoted},
                $reverse{revcomptailquoted}, $reverse{headlen}, $reverse{taillen}, 1,
                $inseq, "R");
            @r_forward_hits = match_positions_optimise($reverse{forwardheadquoted},
                $reverse{forwardtailquoted}, $reverse{headlen}, $reverse{taillen}, 0,
                $inseq, "r");
            @f_revcomp_hits = match_positions_optimise($forward{revcompheadquoted},
                $forward{revcomptailquoted}, $forward{headlen}, $forward{taillen}, 1,
                $inseq, "f");

        } elsif ($o_focalsites) {

            if (not exists $focalsites{$this_seqname} and $this_seqname !~ /^chrUn/) {
                print STDERR "No focal sites on --ref sequence $this_seqname\n";
                next;
            } else {
                if ($this_seqname !~ /^chrUn/) {
                    print STDERR scalar(@{$focalsites{$this_seqname}})." focal sites on --ref sequence $this_seqname\n";
                }
            }

            print STDERR "Matching F, R, r and f primers near focal sites ...\n" if $o_verbose;
            @f_forward_hits = match_positions_focal($forward{forwardquoted}, $inseq,
                                                    $focalsites{$this_seqname}, "F");
            @r_revcomp_hits = match_positions_focal($reverse{revcompquoted}, $inseq,
                                                    $focalsites{$this_seqname}, "R");
            @r_forward_hits = match_positions_focal($reverse{forwardquoted}, $inseq,
                                                    $focalsites{$this_seqname}, "r");
            @f_revcomp_hits = match_positions_focal($forward{revcompquoted}, $inseq,
                                                    $focalsites{$this_seqname}, "f");

        } else {

            print STDERR "Matching F, R, r and f primers sequentially ...\n"; # if $o_verbose;
            @f_forward_hits = match_positions($forward{forwardquoted}, $inseq, "F");
            @r_revcomp_hits = match_positions($reverse{revcompquoted}, $inseq, "R");
            @r_forward_hits = match_positions($reverse{forwardquoted}, $inseq, "r");
            @f_revcomp_hits = match_positions($forward{revcompquoted}, $inseq, "f");
        }

    }

    # The remainder of the code in this loop is quick, no need for threads

    if ($o_showmismatches) {
        # Go through each set of hits, find mismatches vs. the original primer
        # and add an extra field to each describing the mismatches.
        show_mismatches(\@f_forward_hits, $forward{primer});
        show_mismatches(\@r_revcomp_hits, $reverse{revprimer});
        show_mismatches(\@r_forward_hits, $reverse{primer});
        show_mismatches(\@f_revcomp_hits, $forward{revprimer});
    }

    # Sort and remove duplicate hits that start at the same position.  So long
    # as the sort is stable, the order enforces the duplicate selection
    # hierarchy described in the help.
    #
    my @forward_hits = sort { $a->[0] <=> $b->[0] } (@f_forward_hits, @r_forward_hits);
    my @revcomp_hits = sort { $a->[0] <=> $b->[0] } (@f_revcomp_hits, @r_revcomp_hits);
    my $n_forward_dups = remove_duplicate_intervals(\@forward_hits);
    my $n_revcomp_dups = remove_duplicate_intervals(\@revcomp_hits);

    next if not @forward_hits and not @revcomp_hits;  # no hits found

    print STDERR $this_seqname.":".iftag().
                 " forward hits ".scalar(@forward_hits)." ($n_forward_dups dups),".
                 " revcomp hits ".scalar(@revcomp_hits)." ($n_revcomp_dups dups)\n";

    dump_primer_hits($inseq, \@forward_hits, \@revcomp_hits);

    dump_amplicon_internal_hits($inseq, \@forward_hits, \@revcomp_hits);

}

$in->close() if $in;
$out_seq->close() if $out_seq;
$out_bed->close() if $out_bed;
$out_internalseq->close() if $out_internalseq;
$out_internalbed->close() if $out_internalbed;
$out_primerseq->close() if $out_primerseq;
$out_primerbed->close() if $out_primerbed;


# ---- local subroutines -----------------------------------



# By default Bio::Tools::SeqPattern->expand() replaces N with . in the
# regex it returns.  Though this is strictly correct when enforcing a
# DNA alphabet, in some cases it might be better to be more explicit.
# This replaces '.' with '[ACTGN]'.
#
# For complex searches involving lots of allowed mismatches, it might
# be faster to keep the dots, so I have made the default not to expand
# dots.  I have not benchmarked this.
#
sub expand_dot($) {
    my $pat = shift;
    $pat =~ s/\./[ACTGN]/g if $o_expand_dot;
    return $pat;
}



# Prepare a primer for searching by creating a hash for a primer sequence,
# passed as the single argument in one of three forms:
#
#    1. straight sequence:    CTYNARG...
#    2. annotated sequence:   name:direction:CTYNARG...
#    3. Bio::Seq object (NOT IMPLEMENTED YET)
#
# it prepares a hash containing objects prepared for searching for that primer.
# Included are:
#
#     name            name of the primer (if supplied)
#     dir             direction of the primer (if supplied)
#     primer          sequence of the primer as provided
#     revprimer       reverse-complement of the primer sequence
#     Seq             Bio::Seq object for the primer
#     SeqPattern      Bio::Tools::SeqPattern object for the primer
#     forwardpattern  regex for the forward (given) orientation of the primer
#     forwardquoted   a quoted 'qr/.../aai' version of forwardpattern
#     revcomppattern  regex for the reverse complement of the given primer
#     revcompquoted   a quoted 'qr/.../aai' version of revcomppattern
#     IUPAC           Bio::Tools::IUPAC object for the given primer
#     count           number of concrete sequences formable from primer
#
# If there are mismatches, then there is a forward0, revcomp0, IUPAC0,
# count0 for the non-mismatch sequences.  forwardpattern, revcomppattern,
# count are all with reference to the mismatch patterns.
#
sub prepare_primer($) {
    my ($primer) = @_;
    my %dest;
    if (index($primer, ":") >= 0) {
        my @p = split /:/, $primer;
        die "format is   name:dir:sequence" if @p != 3;
        $dest{name} = $p[0];
        $dest{dir} = $p[1];
        $primer = $p[2];
    }
    $dest{primer} = $primer;
    my $s = Bio::Seq->new(-seq => $primer, -alphabet => 'dna');
    $dest{Seq} = $s;
    my $seqpattern = Bio::Tools::SeqPattern->new(-seq => $s->seq(), -type => 'dna');
    $dest{revprimer} = $seqpattern->revcom()->str();
    $dest{SeqPattern} = $seqpattern;
    if ($o_mismatch_simple) {
        my ($mmpat, $headpat, $tailpat, $mmcount, $head, $tail) = apply_mismatch_simple(
            $primer, $o_mm_int1, $o_mm_int2, $o_mm_int3);
        $dest{forwardpattern} = $mmpat;
        $dest{forwardheadpattern} = $headpat;
        $dest{forwardtailpattern} = $tailpat;
        $dest{forwardhead} = $head;
        $dest{forwardtail} = $tail;
        $dest{headlen} = $o_mm_int2;
        $dest{taillen} = length($primer) - $o_mm_int2;
        $dest{count} = $mmcount;
        $dest{revcomppattern} = Bio::Tools::SeqPattern->new(-seq => $mmpat, -type => 'dna')->revcom()->expand();
        $dest{revcompheadpattern} = Bio::Tools::SeqPattern->new(-seq => $headpat, -type => 'dna')->revcom()->expand();
        $dest{revcomptailpattern} = Bio::Tools::SeqPattern->new(-seq => $tailpat, -type => 'dna')->revcom()->expand();
        $dest{mismatch} = $o_mismatch_simple;
        $dest{forward0} = expand_dot($seqpattern->expand());
        $dest{revcomp0} = expand_dot($seqpattern->revcom(1)->expand());
        my $iupac = Bio::Tools::IUPAC->new(-seq => $s);
        $dest{IUPAC0} = $iupac;
        $dest{count0} = $iupac->count();
        if ($o_verbose) {
            print STDERR "forwardpattern      $dest{forwardpattern}\n";
            print STDERR "revcomppattern      $dest{revcomppattern}\n";
            print STDERR "headlen             $dest{headlen}\n";
            print STDERR "taillen             $dest{taillen}\n";
            print STDERR "forwardhead         $dest{forwardhead}\n";
            print STDERR "forwardtail         $dest{forwardtail}\n";
            print STDERR "forwardheadpattern  $dest{forwardheadpattern}\n";
            print STDERR "revcompheadpattern  $dest{revcompheadpattern}\n";
            print STDERR "forwardtailpattern  $dest{forwardtailpattern}\n";
            print STDERR "revcomptailpattern  $dest{revcomptailpattern}\n";
            print STDERR "forward0            $dest{forward0}\n";
            print STDERR "revcomp0            $dest{revcomp0}\n";
        }
        $dest{forwardheadquoted} = qr/$dest{forwardheadpattern}/aai;
        $dest{forwardtailquoted} = qr/$dest{forwardtailpattern}/aai;
        $dest{revcompheadquoted} = qr/$dest{revcompheadpattern}/aai;
        $dest{revcomptailquoted} = qr/$dest{revcomptailpattern}/aai;
    } else {
        $dest{forwardpattern} = expand_dot($seqpattern->expand());
        $dest{revcomppattern} = expand_dot($seqpattern->revcom(1)->expand());
        my $iupac = Bio::Tools::IUPAC->new(-seq => $s);
        $dest{IUPAC} = $iupac;
        $dest{count} = $iupac->count();
    }
    $dest{forwardquoted} = qr/$dest{forwardpattern}/aai;
    print STDERR "forwardquoted processed by ".
        ($dest{forwardquoted}->isa("re::engine::RE2") ? "RE2" : "Perl RE")."\n" if $o_verbose;
    $dest{revcompquoted} = qr/$dest{revcomppattern}/aai;
    return %dest;
}



# Construct a list of sequences having a given number of mismatches within 
# its full length.  $seq is the sequence, $mism is the number of mismatches
# to apply, $regexs is a reference to an array to hold the individual regexs,
# and $degens a reference to an array to hold the individual degenerate
# sequences.
#
# There is a cleaner way to put this code together but I just haven't taken
# the time to find it yet as this is working fine.
#
sub create_mismatch($$$$) {
    my ($seq, $mism, $degens, $pats) = @_;
    my $len = length($seq);
    undef @$degens;
    undef @$pats;
    print STDERR "create_mismatch: seq = $seq, mism = $mism\n" if $o_debug_mismatch;
    if ($mism == 1) {
        for (my $i = 0; $i < $len; ++$i) {
            my $s = $seq;
            substr($s, $i, 1) = "N";
            push @$degens, $s;
            my $sp = Bio::Tools::SeqPattern->new(-seq => $s, -type => 'dna');
            my $pat = expand_dot($sp->expand());
            print STDERR "i = $i, pat = $pat\n" if $o_debug_mismatch;
            push @$pats, $pat;
        }
    } elsif ($mism == 2) {
        for (my $i = 0; $i < $len - 1; ++$i) {
            my $s = $seq;
            substr($s, $i, 1) = "N";
            for (my $j = $i + 1; $j < $len; ++$j) {
                my $ss = $s;
                substr($ss, $j, 1) = "N";
                push @$degens, $ss;
                my $sp = Bio::Tools::SeqPattern->new(-seq => $ss, -type => 'dna');
                my $pat = expand_dot($sp->expand());
                print STDERR "i = $i, pat = $pat\n" if $o_debug_mismatch;
                push @$pats, $pat;
            }
        }
    } elsif ($mism == 3) {
        for (my $i = 0; $i < $len - 2; ++$i) {
            my $s = $seq;
            substr($s, $i, 1) = "N";
            for (my $j = $i + 1; $j < $len - 1; ++$j) {
                my $ss = $s;
                substr($ss, $j, 1) = "N";
                for (my $k = $j + 1; $k < $len; ++$k) {
                    my $sss = $ss;
                    substr($sss, $k, 1) = "N";
                    push @$degens, $sss;
                    my $sp = Bio::Tools::SeqPattern->new(-seq => $sss, -type => 'dna');
                    my $pat = expand_dot($sp->expand());
                    print STDERR "i = $i, pat = $pat\n" if $o_debug_mismatch;
                    push @$pats, $pat;
                }
            }
        }
    } elsif ($mism == 4) {
        for (my $i = 0; $i < $len - 3; ++$i) {
            my $s = $seq;
            substr($s, $i, 1) = "N";
            for (my $j = $i + 1; $j < $len - 2; ++$j) {
                my $ss = $s;
                substr($ss, $j, 1) = "N";
                for (my $k = $j + 1; $k < $len - 1; ++$k) {
                    my $sss = $ss;
                    substr($sss, $k, 1) = "N";
                    for (my $l = $k + 1; $l < $len; ++$l) {
                        my $ssss = $sss;
                        substr($ssss, $l, 1) = "N";
                        push @$degens, $ssss;
                        my $sp = Bio::Tools::SeqPattern->new(-seq => $ssss, -type => 'dna');
                        my $pat = expand_dot($sp->expand());
                        print STDERR "i = $i, pat = $pat\n" if $o_debug_mismatch;
                        push @$pats, $pat;
                    }
                }
            }
        }
    } elsif ($mism == 5) {
        for (my $i = 0; $i < $len - 4; ++$i) {
            my $s = $seq;
            substr($s, $i, 1) = "N";
            for (my $j = $i + 1; $j < $len - 3; ++$j) {
                my $ss = $s;
                substr($ss, $j, 1) = "N";
                for (my $k = $j + 1; $k < $len - 2; ++$k) {
                    my $sss = $ss;
                    substr($sss, $k, 1) = "N";
                    for (my $l = $k + 1; $l < $len - 1; ++$l) {
                        my $ssss = $sss;
                        substr($ssss, $l, 1) = "N";
                        for (my $m = $l + 1; $m < $len; ++$m) {
                            my $sssss = $ssss;
                            substr($sssss, $m, 1) = "N";
                            push @$degens, $sssss;
                            my $sp = Bio::Tools::SeqPattern->new(-seq => $sssss, -type => 'dna');
                            my $pat = expand_dot($sp->expand());
                            print STDERR "i = $i, pat = $pat\n" if $o_debug_mismatch;
                            push @$pats, $pat;
                        }
                    }
                }
            }
        }
    } else {
        die "unrecognised number of mismatches $mism";
    }
}



# Construct regex from a degenerate primer ($p) having a given number of
# mismatches ($head_mism) within a given 5' length of sequence ($len), and
# additional mismatches ($tail_mism) in the remainder of the sequence.
#
sub apply_mismatch_simple($$$$) {
    my ($p, $head_mism, $len, $tail_mism) = @_;
    print STDERR "apply_mismatch_simple: p = $p, head_mism = $head_mism, len = $len, tail_mism = $tail_mism\n" if $o_debug_mismatch;
    my ($head, $tail) = (substr($p, 0, $len), substr($p, $len));
    print STDERR "head = $head, tail = $tail\n" if $o_debug_mismatch;
    my ($head_count, $tail_count) = (1, 1);
    my ($head_pat, $tail_pat);
    if ($head_mism) {
        my (@degen, @pats);
        create_mismatch($head, $head_mism, \@degen, \@pats);
        $head_pat = '(' . join('|', @pats) . ')';
        $head_count = count_degen(\@degen) if not $o_skip_count;
    } else {
        $head_pat = expand_dot(Bio::Tools::SeqPattern->new(
                -seq => $head, -type => 'dna')->expand());
        $head_count = Bio::Tools::IUPAC->new(-seq => Bio::Seq->new(
                -seq => $head, -alphabet => 'dna'))->count();
    }
    if ($tail_mism) {
        my (@degen, @pats);
        create_mismatch($tail, $tail_mism, \@degen, \@pats);
        $tail_pat = '(' . join('|', @pats) . ')';
        $tail_count = count_degen(\@degen) if not $o_skip_count;
    } else {
        $tail_pat = expand_dot(Bio::Tools::SeqPattern->new(
                -seq => $tail, -type => 'dna')->expand());
        $tail_count = Bio::Tools::IUPAC->new(-seq => Bio::Seq->new(
                -seq => $tail, -alphabet => 'dna'))->count();
    }
    my $full_pat = $head_pat . $tail_pat;
    if ($o_debug_mismatch) {
        print STDERR "
apply_mismatch_simple: head = $head, head_pat = $head_pat
apply_mismatch_simple: tail = $tail, tail_pat = $tail_pat
apply_mismatch_simple: full_pat = $full_pat
";
    }
    my $count = $o_skip_count ? -1 : $head_count * $tail_count;
    return ($full_pat, $head_pat, $tail_pat, $count, $head, $tail);
}



# Calculate the number of concrete sequences represented by a mismatch-simple
# sequence with a list of alternate mismatch sequences (@$degen).  Use
# Bio::Tools::IUPAC, to unroll each head sequence, counting the unique
# sequences across all head sequences.
#
sub count_degen($) {
    my ($degen) = @_;
    my %h;
    my ($u, $n) = (0, 0);
    print STDERR "count_degen: Counting concrete sequences from ".scalar(@$degen)." degen sequences ...\n";# if $o_verbose;
    foreach my $h (@$degen) {
        ++$n;
        my $iupac = Bio::Tools::IUPAC->new(-seq =>
            Bio::Seq->new(-seq => $h, -alphabet => 'dna'));
        while (my $uniqueseq = $iupac->next_seq()) {
            $h{$uniqueseq->seq()}++;
            ++$u;
        }
        print STDERR "count_degen: After $n-th degen sequence, $u unrolled and ".scalar(keys(%h))." unique concrete sequences\n" if ! ($n % 20);# and $o_verbose;
    }
    my $count = scalar keys %h;
    print STDERR "count_degen: Completed counting $n degen sequences: $u unrolled and $count unique concrete sequences\n";# if $o_verbose;
    return $count;
}



# Count the number of mismatches
#
# $pat should be in the same orientation as the hits in @$hits, which are
# always forward
#
sub show_mismatches($$) {
    my ($hits, $pat) = @_;
    # each member of @$hits comes in as [ $beg, $end, $hit, $id ]
    foreach my $h (@{$hits}) {
        push @{$h}, show_mismatches2($h->[2], $pat);
    }
}

# Count the number of mismatches in $hit vs. IUPAC sequence $pat.  Both
# variables are scalars.  This is called by show_mismatches() for each
# pairwise comparison.
#
# $pat should be in the same orientation as $hit
#
sub show_mismatches2($$) {
    my ($hit, $pat) = @_;
    my @hchar = map { uc } split //, $hit;
    my @pchar = map { uc } split //, $pat;
    die "show_mismatches2: pattern and hit lengths don't match, ".scalar @pchar." vs ".scalar @hchar if @pchar != @hchar;
    my $n_mismatches = 0;
    my $mismatch_string = "0" x @hchar;
    foreach my $i (0..$#pchar) {
        # If the character in the hit sequence is not part of the ambiguity
        # of the same character in the pattern, then it is a mismatch.
        if (not exists $iupac{$pchar[$i]}{$hchar[$i]}) {
            ++$n_mismatches;
            substr($mismatch_string, $i, 1) = "1";
        }
    }
    # add mismatch message
    $mismatch_string = "0" if $n_mismatches == 0;
    return "mism:$n_mismatches:".scalar @pchar.":$mismatch_string";
}



# Passed in a pattern quoted with 'qr/.../aai', a reference to a sequence to
# search, and an ID to mark each hit.  Returns an array of anonymous arrays
# containing the 0-based beginning and end of the hit and the sequence of the
# hit.  The interval is [beg, end), the same as a BED interval, and each
# anonymous array contains
#
# [ $beg, $end, $hit_sequence, $id ]
#
sub match_positions($$$) {
    my ($pat, $bioseq, $id) = @_;
    my ($seqname, $seq) = ($bioseq->display_id(), $bioseq->seq());
    my @ans;
    while ($seq =~ m/$pat/aaig) {
        print STDERR "match_positions: hit pos = ".pos($seq)."\n" if $o_debug_match;
        my ($beg, $end) = ($-[0], $+[0]);
        my $hit = substr($seq, $beg, $end - $beg);
        print STDERR "match_positions: $id   $beg-$end   $hit\n" if $o_debug_match;
        push @ans, [ $beg, $end, $hit, $id ];
        pos($seq) = $beg + 1 if $o_overlap;
    }
    return @ans;
}



# Passed in a pattern quoted with 'qr/.../aai', a Bio::Seq object containing a
# sequence to search, a list of sites to focus on, L-R boundaries in BED
# coordinates, and an ID to mark each hit.  Returns an array of anonymous
# arrays containing the 0-based beginning and end of the hit and the sequence
# of the hit.  The interval is [beg, end), the same as a BED interval, and each
# anonymous array contains
#
# [ $beg, $end, $hit_sequence, $focalid ]
#
# where $focalid is formed from the $id value passed in as the 4th argument,
# plus the coordinates of the focal site for which this hit was found.
#
sub match_positions_focal($$$$) {
    my ($pat, $bioseq, $sites, $id) = @_;
    my ($seqname, $seq) = ($bioseq->display_id(), $bioseq->seq());
    # we also use $o_focalbounds_up and $o_focalbounds_down
    my @ans;
    foreach my $site (@$sites) {
        my $left = $site->[0] - $o_focalbounds_up;
        my $right = $site->[1] + $o_focalbounds_down;
        $left = 0 if $left < 0;
        $right = $bioseq->length() if $right > $bioseq->length();
        my $leftoff = sprintf("%+d", $left - $site->[0]);
        my $rightoff = sprintf("%+d", $right - $site->[1]);
        # already checked for validity when loading %focalsites hash
        my $focalid = "$id:".$site->[0]."($leftoff)-".$site->[1]."($rightoff)";
        my $focalseq = substr($seq, $left, $right - $left);
        print STDERR "match_positions_focal: focal site extracted: $focalid\n" if $o_debug_focal;
        while ($focalseq =~ m/$pat/aaig) {
            print STDERR "match_positions_focal focal hit pos = ".pos($focalseq)."\n" if $o_debug_focal;
            my ($beg, $end) = ($-[0], $+[0]);
            my $hit = substr($focalseq, $beg, $end - $beg);
            $beg += $left; $end += $left;
            print STDERR "match_positions_focal: focal hit identified: $focalid  $beg-$end  $hit\n" if $o_debug_focal;
            push @ans, [ $beg, $end, $hit, $focalid ];
            pos($focalseq) = $beg + 1 if $o_overlap;
        }
    }
    return @ans;
}



# Passed in a pattern quoted with 'qr/.../aai', a reference to a sequence to
# search, and an ID to mark each hit.  Returns an array of anonymous arrays
# containing the 0-based beginning and end of the hit and the sequence of the
# hit.  The interval is [beg, end), the same as a BED interval, and each
# anonymous array contains
#
# [ $beg, $end, $hit_sequence ]
#
###
#
# @f_revcomp_hits = match_positions_optimise($forward{revcompheadquoted},
#     $forward{revcomptailquoted}, $forward{headlen}, $forward{taillen}, 1,
#     \$this_sequence, "f");
#
sub match_positions_optimise($$$$$$$) {
    my ($headpat, $tailpat, $headlen, $taillen, $is_rc, $bioseq, $id) = @_;
    my @ans;
    my ($head_hits, $tail_hits) = (0, 0);
    my ($seqname, $seq) = ($bioseq->display_id(), $bioseq->seq());
    while ($seq =~ m/$tailpat/aaig) {
        print STDERR "match_positions_optimise: tail pos = ".pos($seq)."\n" if $o_debug_optimise;
        my ($tailbeg, $tailend) = ($-[0], $+[0]);
        ++$tail_hits;
        my $tail = substr($seq, $tailbeg, $tailend - $tailbeg);
        if ($o_debug_optimise) {
            print STDERR "match_positions_optimise: $id  tail HIT #$tail_hits  $tailbeg-$tailend   $tail  $forward{forwardtail} ".show_mismatches2($tail, $forward{forwardtail})."\n";
        }
        my ($headbeg, $headend);
        if ($is_rc) {
            $headbeg = $tailend;
            $headend = $headbeg + $headlen;
        } else {
            $headend = $tailbeg;
            $headbeg = $headend - $headlen;
        }
        my $head = substr($seq, $headbeg, $headend - $headbeg);
        if ($o_debug_optimise) {
            print STDERR "match_positions_optimise: $id  $headbeg-$headend   $head  $forward{forwardhead} ".show_mismatches2($head, $forward{forwardhead})."\n";
            #print STDERR "match_positions_optimise: $id  $headbeg-$headend   ".trunc($headpat)."\n";
        }
        if ($head =~ /$headpat/aai) {
            print STDERR "match_positions_optimise: head pos = ".pos($seq)."\n" if $o_debug_optimise;
            ++$head_hits;
            if ($o_debug_optimise) {
                print STDERR "match_positions_optimise: head HIT #$head_hits ".trunc($headpat)." matches  $head\n";
            }
            my ($beg, $end, $hit);
            if ($is_rc) {
                $beg = $tailbeg;
                $end = $headend;
                $hit = $tail . $head;
            } else {
                $beg = $headbeg;
                $end = $tailend;
                $hit = $head . $tail;
            }
            push @ans, [ $beg, $end, $hit, $id ];
            # reset to just after the tail hit
            pos($seq) = $tailbeg + 1 if $o_optimise;
        } else {
            if ($o_debug_optimise) {
                print STDERR "match_positions_optimise: head miss, ".trunc($headpat)." vs. $head\n";
            }
            # Since this is 'no hit', reset match restart position (which is
            # after the last character of the match by default) to the first
            # character after the beginning of the tail hit
            pos($seq) = $tailbeg + 1;
        }
    }
    return @ans;
}



# When pass a reference to an array of intervals, removes all intervals with the
# same start and stop sites (->[0] and ->[1]) and returns the number of duplicate
# intervals removed.
#
sub remove_duplicate_intervals($) {
    my $a = shift;
    my %seen;
    my $n = scalar(@$a);
    @$a = grep { ! $seen{$_->[0]."-".$_->[1]}++ } @$a;
    return $n - scalar(@$a);
}



# Dump hits for primer sequences, if requested.  Join hits, sort,
# produce BED and/or Fasta files.
#
sub dump_primer_hits($$$) {
    my ($bioseq, $forward_hits, $revcomp_hits) = @_;
    my ($seqname, $seq) = ($bioseq->display_id(), $bioseq->seq());

    my @all_hits = sort { $a->[0] <=> $b->[0] } ( @$forward_hits, @$revcomp_hits );
    my $n_all_dups = remove_duplicate_intervals(\@all_hits);
    print STDERR "dump_primer_hits: $seqname:".iftag()." all hits ".
                 scalar(@all_hits)." ($n_all_dups dups)\n" if $o_verbose;

    return if not $o_primerbed and not $o_primerseq;

    foreach my $h (@all_hits) {
        my $hit = $h->[2];  # sequence
        my $id = $h->[3];   # id of sequence (F, R, f, r)
        if ($o_primerbed) {
            my $name = "$id:$hit";  # the hit sequence itself
            $name = "$tag:$name" if $tag;
            $name .= "," . $h->[4] if $o_showmismatches;
            $out_primerbed->print($seqname."\t".$h->[0]."\t".$h->[1]."\t".$name."\n");
        }
        if ($o_primerseq) {
            # use base-1 GFF-type intervals in Fasta name
            my $name = "$seqname:".($h->[0] + 1)."-".$h->[1];
            $name .= ":$tag" if $tag;
            $name .= ":$id";
            $name .= "," . $h->[4] if $o_showmismatches;
            my $hitseq = Bio::Seq->new(-id => $name,
                                       -seq => $h->[2],
                                       -alphabet => 'dna');
            $out_primerseq->write_seq($hitseq);
        }
    }
}



# Dump hits for amplicon and internal sequences, if requested.  Construct
# amplicons, sort into too-short, too-long, and just-right lengths, count them
# up, and produce BED and/or Fasta files for amplicons and/or internal regions.
#
sub dump_amplicon_internal_hits($$$) {
    my ($bioseq, $forward_hits, $revcomp_hits) = @_;
    my ($seqname, $seq) = ($bioseq->display_id(), $bioseq->seq());
    # amplicons extend between forward_hits->[0] and revcomp_hits->[1]
    # internal regions extend between forward_hits->[1] and revcomp_hits->[0]
    my @amp_short; # too short  0 <=      < $o_min
    my @amp_long; # too long   $o_max <  <= $o_maxmax
    my @amp; # just right $o_min <= <= $o_max
    foreach my $f (@$forward_hits) {
        foreach my $r (@$revcomp_hits) {
            next if $r->[0] < $f->[1];  # at least de-overlap the primers
            my ($beg, $end) = ( $f->[0], $r->[1] );
            my $primers_id = $f->[3] . "," . $r->[3];
            my ($intbeg, $intend) = ( $f->[1], $r->[0] );
            my $amp_len = $end - $beg;
            next if $amp_len < 0 or $amp_len > $o_maxmax;
            my $amplicon = substr($seq, $beg, $end - $beg);
            my $internal = substr($seq, $intbeg, $intend - $intbeg);
            # this uses more storage than necessary but it may not matter
            my $arr = [ $beg, $end, $amplicon, $primers_id, $intbeg, $intend, $internal ];
            $arr->[7] = $f->[4] . "," . $r->[4] if $o_showmismatches;
            if ($amp_len < $o_min) {
                push @amp_short, $arr;
            } elsif ($amp_len > $o_max) {
                push @amp_long, $arr;
            } else {
                push @amp, $arr;
            }
        }
    }
    my $n_dup = remove_duplicate_intervals(\@amp);
    my $n_short_dup = remove_duplicate_intervals(\@amp_short);
    my $n_long_dup = remove_duplicate_intervals(\@amp_long);
    print STDERR $seqname.":".iftag().
                 " amplicons ".scalar(@amp)." ($n_dup dups),".
                 " tooshort ".scalar(@amp_short)." ($n_short_dup dups),".
                 " toolong ".scalar(@amp_long)." ($n_long_dup dups)\n";

    return if not $o_bed and not $o_seq;

    foreach my $h (@amp) {
        if ($o_bed) {
            my $name = "$tag:".$h->[3].":".length($h->[2]);
            $name .= "," . $h->[7] if $o_showmismatches;
            $out_bed->print($seqname."\t".$h->[0]."\t".$h->[1]."\t".$name."\n");
        }
        if ($o_seq) {
            # use base-1 GFF-type intervals in Fasta name
            my $name = "$seqname:".($h->[0] + 1)."-".$h->[1].":$tag:".$h->[3].":".length($h->[2]);
            $name .= "," . $h->[7] if $o_showmismatches;
            $out_seq->write_seq(Bio::Seq->new(-id => $name,
                                              -seq => $h->[2],
                                              -alphabet => 'dna'));
        }
        if ($o_internalbed) {
            my $name = "$tag:".$h->[3].":".length($h->[6]);
            $name .= "," . $h->[7] if $o_showmismatches;
            $out_internalbed->print($seqname."\t".$h->[4]."\t".$h->[5]."\t".$name."\n");
        }
        if ($o_internalseq) {
            # use base-1 GFF-type intervals in Fasta name
            my $name = "$seqname:".($h->[4] + 1)."-".$h->[5].":$tag:".$h->[3].":".length($h->[6]);
            $name .= "," . $h->[7] if $o_showmismatches;
            $out_internalseq->write_seq(Bio::Seq->new(-id => $name,
                                                      -seq => $h->[6],
                                                      -alphabet => 'dna'));
        }
    }
}
