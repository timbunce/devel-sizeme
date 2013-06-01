
use strict;
use Term::ReadKey;

my @steps = (
    {
        perl => q{total_size(1)},
    },
    {
        perl => q{total_size("Hello world!")},
    },
    {
        perl => q{total_size(rand)},
    },
    {
        perl => q{$data = rand(); print "$data\n"; total_size($data)},
    },
    {
        perl => q{$data = [ 42, "Hi!", rand ]; total_size($data)},
    },
    {
        sizeme => q{| cat},
        perl => q{$data = [ 42, "Hi!", rand ]; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --text},
        perl => q{$data = [ 42, "Hi!", rand ]; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{$data = [ 42, "Hi!", rand ]; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{$data = [ 42, "Hi!", rand ]; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{$data = [ { foo => 42 }, { foo => 43 } ]; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{sub fac { my $x=shift; return ($x <= 1) ? $x : $x * fac($x-1) }; $data = \&fac; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{sub fac { my $x=shift; return ($x <= 1) ? $x : $x * fac($x-1) }; fac(3); $data = \&fac; total_size($data)},
    },
    {
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{$data = \%Exporter::; total_size($data)},
    },
    {
        hide => '7',
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{$data = \%Exporter::; total_size($data)},
    },
    {
        hide => '7',
        sizeme => q{| sizeme_store.pl --dot sizeme.dot --open},
        perl => q{perl_size()},
    },
);

sub runstep {
    my ($spec) = @_;
    print "\n";

    my $cmd = "perl -MDevel::SizeMe=:all -e '$spec->{perl}'";

    my @exports;
    local $ENV{SIZEME} = $spec->{sizeme};
    push @exports, "SIZEME='$spec->{sizeme}'";
    local $ENV{SIZEME_HIDE} = $spec->{hide};
    push @exports, "SIZEME_HIDE='$spec->{hide}'";

    print "\$ export @exports\n";
    print "\$ $cmd ";
    my $key = getkey();
    if ($key =~ m/[ npl]/i) {
        print "\012".(" " x 80)."\n";
        return $key;
    }
    print "\n";
    system $cmd;
    print "\n";
    return undef;
}

my $atstep = 0;

while (my $key = runstep($steps[$atstep]) || getkey()) {
    if ($key =~ m/[ n\n]/) { ++$atstep if $atstep < @steps-1; } 
    elsif ($key =~ m/[p]/) { --$atstep if $atstep > 0; }
    elsif ($key =~ m/[l]/) { $atstep = @steps-1; }
    else {
        print "[press n, p, l, or q]\n";
        $key = getkey();
        redo;
    }
}


sub getkey {
    STDOUT->flush();
    ReadMode 'raw';
    my $key = ReadKey(0);
    ReadMode 'normal';
    exit 1 if $key =~ /[q\x03\x04]/i;
    return $key;
}
