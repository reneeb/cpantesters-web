package CPAN::Testers::Web;
our $VERSION = '0.001';
# ABSTRACT: Write a sentence about what it does

=head1 SYNOPSIS

    $ cpantesters-web daemon
    Listening on http://*:5000

=head1 DESCRIPTION

This is the main L<CPAN Testers|http://cpantesters.org> web application.
This application is the main platform for exploring, searching, and
interacting with CPAN Testers data.

=head1 SEE ALSO

L<Mojolicious>,
L<CPAN::Testers::Schema>,
L<http://github.com/cpan-testers/cpantesters-project>,
L<http://www.cpantesters.org>

=cut

use Mojo::Base 'Mojolicious';
use CPAN::Testers::Web::Base;
use File::Share qw( dist_dir dist_file );
use Log::Any::Adapter;
use File::Spec::Functions qw( catdir catfile );

has schema =>;

=method startup

    # Called automatically by Mojolicious

This method starts up the application, loads any plugins, sets up routes,
and registers helpers.

=cut

sub startup ( $app ) {
    $app->log( Mojo::Log->new ); # Log only to STDERR
    unshift @{ $app->renderer->paths },
        catdir( dist_dir( 'CPAN-Testers-Web' ), 'templates' );
    unshift @{ $app->static->paths },
        catdir( dist_dir( 'CPAN-Testers-Web' ), 'public' );
    unshift @{ $app->commands->namespaces }, 'CPAN::Testers::Web::Command';

    $app->moniker( 'web' );
    # This application has no configuration yet
    $app->plugin( Config => {
        default => { }, # Allow living without config file
    } );

    # XXX We need a better way to handle schema objects for other
    # languages, which will be CPAN::Testers::Schema object connected to
    # different databases
    $app->helper( 'schema.perl5' => sub {
        require CPAN::Testers::Schema;
        state $schema = $app->schema || CPAN::Testers::Schema->connect_from_config;
        return $schema;
    } );
    $app->helper( 'schema.web' => sub {
        require CPAN::Testers::Web::Schema;
        state $schema = CPAN::Testers::Web::Schema->connect_from_config;
        return $schema;
    } );

    Log::Any::Adapter->set( 'MojoLog', logger => $app->log );

    if ( $app->config->{Minion} ) {
        $app->plugin( 'Minion', $app->config->{Minion} );
        my $under = $app->routes->under('/minion' =>sub {
            my $c = shift;
            return 1 if $c->req->url->to_abs->userinfo eq 'Bender:rocks';
            $c->res->headers->www_authenticate('Basic');
            $c->render(text => 'Authentication required!', status => 401);
            return undef;
        });
        $app->plugin('Minion::Admin' => {route => $under});
    }

    if ( $app->config->{Yancy} ) {
        my $yancy_auth = $app->routes->under('/yancy' =>sub {
            my $c = shift;
            return 1 if $c->req->url->to_abs->userinfo eq 'Bender:rocks';
            $c->res->headers->www_authenticate('Basic');
            $c->render(text => 'Authentication required!', status => 401);
            return undef;
        });
        $app->plugin( Yancy => {
            %{ $app->config->{Yancy} },
            route => $yancy_auth,
            read_schema => 1,
            collections => {
                LatestIndex => {
                    'x-list-columns' => [qw( dist version author released )],
                },
                MetabaseUser => {
                    'x-list-columns' => [qw( resource fullname email )],
                },
                PerlVersion => {
                    'x-list-columns' => [qw( version perl devel patch )],
                    properties => {
                        version => {
                            description => q{The raw version from the reporter's Config},
                        },
                        perl => {
                            description => 'The parsed / normalized Perl version',
                        },
                        devel => {
                            title => 'Is Devel?',
                            description => 'If true, is a development Perl',
                        },
                        patch => {
                            title => 'Is Patched?',
                            description => 'If true, is a patched Perl',
                        },
                    },
                },
                Release => {
                    description => 'Per-release data, rolled up into a summary',
                    'x-list-columns' => [qw( dist version perlmat patched pass fail na unknown )],
                },
                ReleaseStat => {
                    description => 'Useless table that reduces the Stats (cpanstats) table to a `1` in one of the pass/fail/na/unknown columns. Used to build the Release (release_summary) table.',
                    'x-list-columns' => [qw( dist version perlmat patched pass fail na unknown )],
                },
                Stats => {
                    'x-list-columns' => [qw( id dist version perl osname state tester )],
                },
                Upload => {
                    'x-list-columns' => [qw( dist version author released )],
                },
                TestReport => {
                    'x-list-columns' => [qw( id created )],
                },
            },
        });
    }

    $app->plugin( 'OAuth2', {
        github => {
            key => $ENV{OAUTH2_GITHUB_CLIENT} || 'c6ec2955ddc771fd906d',
            secret => $ENV{OAUTH2_GITHUB_SECRET},
        },
    } );
    my $ua = Mojo::UserAgent->new;
    $app->routes->get( "/yancy/auth/oauth2/github" => sub {
        my ( $c ) = @_;
        my $get_token_args = {
            redirect_uri => $c->url_for("yancy.auth.oauth2.github")->userinfo( undef )->to_abs,
        };
        $c->oauth2->get_token_p( github => $get_token_args )->then( sub {
            return unless my $provider_res = shift;
            ; use Data::Dumper;
            ; $c->app->log->info( Dumper $provider_res );
            $c->session( token => $provider_res->{access_token} );
            my $from = delete $c->session->{ 'yancy.auth.from' } || '/';

            # With this token I can get data from the Github API
            my %headers = (
                # Use v3 API explicitly
                Accept => 'application/vnd.github.v3+json',
                Authorization => sprintf( 'token %s', $provider_res->{access_token} ),
            );
            $ua->get_p( 'https://api.github.com/user', \%headers )->then( sub {
                my ( $tx ) = @_;
                my $login = $tx->res->json->{login};
                my $user = $c->schema->web->resultset( 'Users' )->create({
                    github_login => $login,
                });
                $c->session( user_id => $user->id );
                $c->redirect_to( $from );
            } )
            ->catch( sub {
                my $error = shift;
                $c->app->log->error( 'Error getting Github user: ' . $error );
                $c->render( "yancy/auth/oauth2", provider => 'github', error => $error );
            } );
        } )
        ->catch( sub {
            my $error = shift;
            $c->app->log->error( 'Error getting OAuth2 token: ' . $error );
            $c->render( "yancy/auth/oauth2", provider => 'github', error => $error );
        } );
    } )->name( 'yancy.auth.oauth2.github' );

    $app->helper( current_user => sub {
        my ( $c ) = @_;
        my $user_id = $c->session( 'user_id' ) || return;
        my $user = $c->schema->web->resultset( 'Users' )->find( $user_id );
        if ( !$user ) {
            delete $c->session->{ user_id };
            return;
        }
        return $user;
    } );

    my $auth = $app->routes->under( sub {
        my ( $c ) = @_;
        if ( !$c->current_user ) {
            $c->session( 'yancy.auth.from' => $c->url_for() );
            $c->render( 'yancy/auth', status => 401 );
            return undef;
        }
        return 1;
    } );

    $auth->get( '/user/pause' )->to( 'user#pause' )->name( 'user.pause' );
    $auth->post( '/user/pause' )->to( 'user#update_pause' )->name( 'user.update_pause' );
    $auth->any( '/user/pause/token' )->to( 'user#validate_pause' )->name( 'user.validate_pause' );

    # Compile JS and CSS assets
    $app->plugin( 'AssetPack', { pipes => [qw( Css JavaScript )] } );
    $app->asset->store->paths([
        catdir( dist_dir( 'CPAN-Testers-Web' ), 'node_modules' ),
        @{ $app->static->paths },
    ]);

    $app->asset->process(
        'prereq.js' => qw(
            /jquery/dist/jquery.js
            /bootstrap/dist/js/bootstrap.js
        ),
    );

    $app->asset->process(
        'prereq.css' => qw(
            /bootstrap/dist/css/bootstrap.css
            /bootstrap/dist/css/bootstrap-theme.css
            /font-awesome/css/font-awesome.css
            /css/cpantesters.css
        ),
    );

    # Add static paths to find fonts
    push @{ $app->static->paths },
        catdir( dist_dir( 'CPAN-Testers-Web' ), 'node_modules', 'font-awesome' );

    # Set defaults
    $app->defaults(
        layout => 'default',
    );

    # Add routes
    my $r = $app->routes;

    $r->get( '/user/dist/:dist' )
      ->name( 'user.dist-settings' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'user/dist/settings' );
    } );

    $r->get( '/dist/:dist/#version', { version => 'latest' } )
      ->name( 'dist' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'dist' );
    } );

    $r->get( '/dist' )
      ->name( 'dist-search' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'dist-search' );
    } );

    $r->get( '/author/:author' )
      ->name( 'author' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'author' );
    } );

    $r->get( '/author' )
      ->name( 'author-search' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'author-search' );
    } );

    $r->get( '/tester/:tester/:machine' )
      ->name( 'tester-machine' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'tester-machine' );
    } );

    $r->get( '/tester/:tester' )
      ->name( 'tester' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'tester' );
    } );

    $r->get( '/tester' )
      ->name( 'tester-search' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'tester-search' );
    } );

    $r->get( '/report/:guid' )
      ->name( 'report' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( 'report' );
    } );

    $r->get( '/legacy/cpan/report/:id' )
      ->name( 'legacy-view-report' )
      ->to( 'legacy#view_report' );

    # Add a special route to show the main landing page, which is
    # replaced by a different page in beta mode
    if ( $app->mode eq 'beta' ) {
        $r->get( '/web' )
          ->name( 'web' )
          ->to( cb => sub {
            my ( $c ) = @_;
            $c->render( 'index' );
        } );
    }

    $r->get( '/*tmpl', { tmpl => 'index' } )
      ->name( 'web' )
      ->to( cb => sub {
        my ( $c ) = @_;
        $c->render( $c->stash( 'tmpl' ), variant => $app->mode );
    } );

}

1;

