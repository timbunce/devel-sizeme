
use strict;
# require at least 5.006, it doesn't even compile under 5.005
require 5.006;

# Load the Module::Install bundled in ./inc/
use inc::Module::Install;

name		'Devel-Size';

# Get most of the details from the primary module
all_from	'lib/Devel/Size.pm';

requires	'DynaLoader'	=> 0;
requires	'perl'		=> 5.006;

recommends	'Devel::Size::Report'	=> 0.11;

build_requires	'Test::More'	=> 0.42;

license		'perl';		# from 5.8.8

# It seems not to be possible to specifiy two authors here :/
# Nor does a "maintainer" property exist
author		'Tels <nospam-abuse@bloodgate.com>';

# Do not index these
no_index	directory	=> 'examples';

# Generate the Makefile
WriteAll;
