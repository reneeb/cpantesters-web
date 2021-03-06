use utf8;
package CPAN::Testers::Web::Base;
our $VERSION = '0.001';
# ABSTRACT: Base module for importing standard modules, features, and subs

=head1 SYNOPSIS

    # lib/CPAN/Testers/Web/MyModule.pm
    package CPAN::Testers::Web::MyModule;
    use CPAN::Testers::Web::Base;

    # t/mytest.t
    use CPAN::Testers::Web::Base 'Test';

=head1 DESCRIPTION

This module collectively imports all the required features and modules
into your module. This module should be used by all modules in the
L<CPAN::Testers::Web> distribution. This module should not be used by
modules in other distributions.

This module imports L<strict>, L<warnings>, and L<the sub signatures
feature|perlsub/Signatures>.

=head1 SEE ALSO

=over

=item L<Import::Base>

=back

=cut

use strict;
use warnings;
use base 'Import::Base';

our @IMPORT_MODULES = (
    'strict', 'warnings',
    feature => [qw( :5.24 signatures refaliasing )],
    'CPAN::Testers::Web', # For File::Share to find dist dir
    '>-warnings' => [qw( experimental::signatures experimental::refaliasing )],
);

our %IMPORT_BUNDLES = (
    Result => [
        'DBIx::Class::Candy',
    ],
    ResultSet => [
        'DBIx::Class::Candy::ResultSet',
    ],
    Test => [
        # Do not send out e-mail, hold on to it so we can examine that we're
        # sending the correct e-mails
        sub { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' },
        # This must be loaded before 'Test::More' to fix "ok: plan
        # before you test!" errors caused by the wrong 'ok' sub being
        # imported into the main namespace
        'Email::Stuffer',
        'Test::More', 'Test::Mojo',
    ],
);

1;
