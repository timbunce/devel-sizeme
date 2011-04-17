use 5.008;
use ExtUtils::MakeMaker;

WriteMakefile(
  NAME => 'Devel::Size',
  VERSION_FROM => 'lib/Devel/Size.pm',
  ($ExtUtils::MakeMaker::VERSION >= 6.47 ? (MIN_PERL_VERSION => '5.008') : ()),
  ($ExtUtils::MakeMaker::VERSION >= 6.31 ? (LICENSE => 'perl') : ()),
);
