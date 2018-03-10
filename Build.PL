use 5.006;
use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name        => 'TaskEz',
    license            => 'artistic_2',
    dist_author        => q{John Gravatt <john@gravatt.org>},
    dist_version_from  => 'lib/TaskEz.pm',
    release_status     => 'stable',
    configure_requires => { 'Module::Build' => 0, },
    build_requires     => { 'Test::More' => 0, },
    requires           => {

        #'ABC'              => 1.6,
        #'Foo::Bar::Module' => 5.0401,
        'List::Util'              => 1.50,
        'SQL::Abstract::Complete' => 0,
        'Text::ANSITable'         => 0,
        'Data::Unixish'           => 0,
    },
    add_to_cleanup     => ['TaskEz-*'],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
