#!/usr/bin/perl -w

use strict;
use Test::More tests => 7;
use Devel::Size ':all';
require Tie::Scalar;

{
    my $string = 'Perl Rules';
    my $before_size = total_size($string);
    is($string =~ /Perl/g, 1, 'It had better match');
    cmp_ok($before_size, '>', length $string,
	   'Our string has a non-zero length');
    cmp_ok(total_size($string), '>', $before_size,
	   'size increases due to magic');
}

{
    my $string = 'Perl Rules';
    my $before_size = total_size($string);
    formline $string;
    my $compiled_size = total_size($string);
    cmp_ok($before_size, '>', length $string,
	   'Our string has a non-zero length');
    cmp_ok($compiled_size, '>', $before_size,
	   'size increases due to magic (and the compiled state)');
    # Not fully sure why (didn't go grovelling) but need to use a temporary to
    # avoid the magic being copied.
    $string = '' . $string;
    my $after_size = total_size($string);
    cmp_ok($after_size, '>', $before_size, 'Still larger than initial size');
    cmp_ok($after_size, '<', $compiled_size, 'size decreases due to unmagic');
}
