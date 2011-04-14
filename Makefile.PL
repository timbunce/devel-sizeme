use ExtUtils::MakeMaker;
use Config;

my %options = (       
  NAME => 'Devel::Size',
  LIBS => $Config{cc} eq 'gcc' || $Config{cc} eq 'cc' ? ['-lstdc++'] : '',
  VERSION_FROM => 'lib/Devel/Size.pm',
  CC => $Config{cc} eq 'cl' ? 'cl' : 'g++',
);

WriteMakefile(%options);
