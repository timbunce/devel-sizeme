#!/usr/bin/perl -w
use 5.005;
use ExtUtils::MakeMaker;
use File::Spec::Functions 'catfile';
use strict;

use Config;
(unpack "B*", pack "N", $Config{ptrsize}) =~ /^0+1(0+)$/
    or die "Your pointer size of $Config{ptrsize} is very confusing";
my $ptr_bits = length $1;

write_header(
    'refcounted_he.h' =>
    extract_refcounted_he(catfile($Config{archlib}, 'CORE', 'hv.h'))
);

WriteMakefile(
    OPTIMIZE => "-g",
    NAME => 'Devel::SizeMe',
    VERSION_FROM => 'lib/Devel/SizeMe.pm',
    DEFINE => "-DALIGN_BITS=$ptr_bits",
    PREREQ_PM => {
        'Test::More' => 0,
        'JSON::XS' => 0,
        'HTML::Entities' => 0,
        'Mojolicious::Lite' => 0,
        'Devel::Dwarn' => 0,
        XSLoader => 0,
        ORLite => 0,
    },
    EXE_FILES => [ 'bin/sizeme_store.pl', 'bin/sizeme_graph.pl' ],
    clean => {
        FILES => 'refcounted_he.h',
    },
    (eval $ExtUtils::MakeMaker::VERSION >= 6.47 ? (MIN_PERL_VERSION => '5.005') : ()),
    (eval $ExtUtils::MakeMaker::VERSION >= 6.31 ? (LICENSE => 'perl') : ()),
);

sub extract_refcounted_he {
    my ($header) = @_;
    open my $fh, '<', $header or die $!;

    my $def;
    while (<$fh>) {
        next unless /struct refcounted_he \{/ .. /\};/;
        $def .= $_;
    }
    close $fh or die $!;

    return $def;
}

sub write_header {
    my ($filename, $contents) = @_;
    my $guard_name = uc $filename;
    $guard_name =~ tr/./_/;

    open my $fh, '>', $filename or die $!;
    print { $fh } "#ifndef ${guard_name}\n";
    print { $fh } "#define ${guard_name}\n";
    print { $fh } $contents or die $!;
    print { $fh } "#endif /* ${guard_name} */\n";
    close $fh or die $!;
}
