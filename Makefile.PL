
use strict;

# Load the Module::Install bundled in ./inc/
use inc::Module::Install;

# The name of your distribution
name		'Devel-Size';

# Get most of the details from the primary module
all_from	'lib/Devel/Size.pm';

requires	'DynaLoader'	=> 0;

recommends	'Devel::Size::Report'	=> 0.11;

build_requires	'Test::More'	=> 0.42;

license		'perl';

# It seems not to be possible to specifiy two authors here :/
# Nor does a "maintainer" property exist
author		'Tels <nospam-abuse@bloodgate.com>';

# Do not index these
no_index	directory	=> 'examples';

# Generate the Makefile
WriteAll;
