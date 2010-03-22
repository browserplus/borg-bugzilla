# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# The Initial Developer of the Original Code is Netscape Communications
# Corporation. Portions created by Netscape are
# Copyright (C) 1998 Netscape Communications Corporation. All
# Rights Reserved.
#
# Contributor(s): Bradley Baetz <bbaetz@student.usyd.edu.au>
#                 Erik Stambaugh <erik@dasbistro.com>
#                 A. Karl Kornel <karl@kornel.name>
#                 Marc Schumann <wurblzap@gmail.com>

package Bugzilla;

use strict;

# We want any compile errors to get to the browser, if possible.
BEGIN {
    # This makes sure we're in a CGI.
    if ($ENV{SERVER_SOFTWARE} && !$ENV{MOD_PERL}) {
        require CGI::Carp;
        CGI::Carp->import('fatalsToBrowser');
    }
}

use Bugzilla::Config;
use Bugzilla::Constants;
use Bugzilla::Auth;
use Bugzilla::Auth::Persist::Cookie;
use Bugzilla::CGI;
use Bugzilla::Extension;
use Bugzilla::DB;
use Bugzilla::Install::Localconfig qw(read_localconfig);
use Bugzilla::Install::Requirements qw(OPTIONAL_MODULES);
use Bugzilla::Install::Util;
use Bugzilla::Template;
use Bugzilla::User;
use Bugzilla::Error;
use Bugzilla::Util;
use Bugzilla::Field;
use Bugzilla::Flag;

use File::Basename;
use File::Spec::Functions;
use DateTime::TimeZone;
use Safe;

#####################################################################
# Constants
#####################################################################

# Scripts that are not stopped by shutdownhtml being in effect.
use constant SHUTDOWNHTML_EXEMPT => [
    'editparams.cgi',
    'checksetup.pl',
    'migrate.pl',
    'recode.pl',
];

# Non-cgi scripts that should silently exit.
use constant SHUTDOWNHTML_EXIT_SILENTLY => [
    'whine.pl'
];

#####################################################################
# Global Code
#####################################################################

# $::SIG{__DIE__} = i_am_cgi() ? \&CGI::Carp::confess : \&Carp::confess;

# Note that this is a raw subroutine, not a method, so $class isn't available.
sub init_page {
    (binmode STDOUT, ':utf8') if Bugzilla->params->{'utf8'};

    if (${^TAINT}) {
        # Some environment variables are not taint safe
        delete @::ENV{'PATH', 'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
        # Some modules throw undefined errors (notably File::Spec::Win32) if
        # PATH is undefined.
        $ENV{'PATH'} = '';
    }

    # Because this function is run live from perl "use" commands of
    # other scripts, we're skipping the rest of this function if we get here
    # during a perl syntax check (perl -c, like we do during the
    # 001compile.t test).
    return if $^C;

    # IIS prints out warnings to the webpage, so ignore them, or log them
    # to a file if the file exists.
    if ($ENV{SERVER_SOFTWARE} && $ENV{SERVER_SOFTWARE} =~ /microsoft-iis/i) {
        $SIG{__WARN__} = sub {
            my ($msg) = @_;
            my $datadir = bz_locations()->{'datadir'};
            if (-w "$datadir/errorlog") {
                my $warning_log = new IO::File(">>$datadir/errorlog");
                print $warning_log $msg;
                $warning_log->close();
            }
        };
    }

    # Because of attachment_base, attachment.cgi handles this itself.
    if (basename($0) ne 'attachment.cgi') {
        do_ssl_redirect_if_required();
    }

    # If Bugzilla is shut down, do not allow anything to run, just display a
    # message to the user about the downtime and log out.  Scripts listed in 
    # SHUTDOWNHTML_EXEMPT are exempt from this message.
    #
    # This code must go here. It cannot go anywhere in Bugzilla::CGI, because
    # it uses Template, and that causes various dependency loops.
    if (Bugzilla->params->{"shutdownhtml"} 
        && lsearch(SHUTDOWNHTML_EXEMPT, basename($0)) == -1)
    {
        # Allow non-cgi scripts to exit silently (without displaying any
        # message), if desired. At this point, no DBI call has been made
        # yet, and no error will be returned if the DB is inaccessible.
        if (lsearch(SHUTDOWNHTML_EXIT_SILENTLY, basename($0)) > -1
            && !i_am_cgi())
        {
            exit;
        }

        # For security reasons, log out users when Bugzilla is down.
        # Bugzilla->login() is required to catch the logincookie, if any.
        my $user;
        eval { $user = Bugzilla->login(LOGIN_OPTIONAL); };
        if ($@) {
            # The DB is not accessible. Use the default user object.
            $user = Bugzilla->user;
            $user->{settings} = {};
        }
        my $userid = $user->id;
        Bugzilla->logout();

        my $template = Bugzilla->template;
        my $vars = {};
        $vars->{'message'} = 'shutdown';
        $vars->{'userid'} = $userid;
        # Generate and return a message about the downtime, appropriately
        # for if we're a command-line script or a CGI script.
        my $extension;
        if (i_am_cgi() && (!Bugzilla->cgi->param('ctype')
                           || Bugzilla->cgi->param('ctype') eq 'html')) {
            $extension = 'html';
        }
        else {
            $extension = 'txt';
        }
        print Bugzilla->cgi->header() if i_am_cgi();
        my $t_output;
        $template->process("global/message.$extension.tmpl", $vars, \$t_output)
            || ThrowTemplateError($template->error);
        print $t_output . "\n";
        exit;
    }
}

#####################################################################
# Subroutines and Methods
#####################################################################

sub template {
    my $class = shift;
    $class->request_cache->{language} = "";
    $class->request_cache->{template} ||= Bugzilla::Template->create();
    return $class->request_cache->{template};
}

sub template_inner {
    my ($class, $lang) = @_;
    $lang = defined($lang) ? $lang : ($class->request_cache->{language} || "");
    $class->request_cache->{language} = $lang;
    $class->request_cache->{"template_inner_$lang"}
        ||= Bugzilla::Template->create();
    return $class->request_cache->{"template_inner_$lang"};
}

our $extension_packages;
sub extensions {
    my ($class) = @_;
    my $cache = $class->request_cache;
    if (!$cache->{extensions}) {
        # Under mod_perl, mod_perl.pl populates $extension_packages for us.
        if (!$extension_packages) {
            $extension_packages = Bugzilla::Extension->load_all();
        }
        my @extensions;
        foreach my $package (@$extension_packages) {
            my $extension = $package->new();
            if ($extension->enabled) {
                push(@extensions, $extension);
            }        
        }
        $cache->{extensions} = \@extensions;
    }
    return $cache->{extensions};
}

sub feature {
    my ($class, $feature) = @_;
    my $cache = $class->request_cache;
    return $cache->{feature}->{$feature}
        if exists $cache->{feature}->{$feature};

    my $feature_map = $cache->{feature_map};
    if (!$feature_map) {
        foreach my $package (@{ OPTIONAL_MODULES() }) {
            foreach my $f (@{ $package->{feature} }) {
                $feature_map->{$f} ||= [];
                push(@{ $feature_map->{$f} }, $package->{module});
            }
        }
        $cache->{feature_map} = $feature_map;
    }

    if (!$feature_map->{$feature}) {
        ThrowCodeError('invalid_feature', { feature => $feature });
    }

    my $success = 1;
    foreach my $module (@{ $feature_map->{$feature} }) {
        # We can't use a string eval and "use" here (it kills Template-Toolkit,
        # see https://rt.cpan.org/Public/Bug/Display.html?id=47929), so we have
        # to do a block eval.
        $module =~ s{::}{/}g;
        $module .= ".pm";
        eval { require $module; 1; } or $success = 0;
    }
    $cache->{feature}->{$feature} = $success;
    return $success;
}

sub cgi {
    my $class = shift;
    $class->request_cache->{cgi} ||= new Bugzilla::CGI();
    return $class->request_cache->{cgi};
}

sub input_params {
    my ($class, $params) = @_;
    my $cache = $class->request_cache;
    # This is how the WebService and other places set input_params.
    if (defined $params) {
        $cache->{input_params} = $params;
    }
    return $cache->{input_params} if defined $cache->{input_params};

    # Making this scalar makes it a tied hash to the internals of $cgi,
    # so if a variable is changed, then it actually changes the $cgi object
    # as well.
    $cache->{input_params} = $class->cgi->Vars;
    return $cache->{input_params};
}

sub localconfig {
    my $class = shift;
    $class->request_cache->{localconfig} ||= read_localconfig();
    return $class->request_cache->{localconfig};
}

sub params {
    my $class = shift;
    $class->request_cache->{params} ||= Bugzilla::Config::read_param_file();
    return $class->request_cache->{params};
}

sub user {
    my $class = shift;
    $class->request_cache->{user} ||= new Bugzilla::User;
    return $class->request_cache->{user};
}

sub set_user {
    my ($class, $user) = @_;
    $class->request_cache->{user} = $user;
}

sub sudoer {
    my $class = shift;    
    return $class->request_cache->{sudoer};
}

sub sudo_request {
    my ($class, $new_user, $new_sudoer) = @_;
    $class->request_cache->{user}   = $new_user;
    $class->request_cache->{sudoer} = $new_sudoer;
    # NOTE: If you want to log the start of an sudo session, do it here.
}

sub page_requires_login {
    return $_[0]->request_cache->{page_requires_login};
}

sub login {
    my ($class, $type) = @_;

    return $class->user if $class->user->id;

    my $authorizer = new Bugzilla::Auth();
    $type = LOGIN_REQUIRED if $class->cgi->param('GoAheadAndLogIn');

    if (!defined $type || $type == LOGIN_NORMAL) {
        $type = $class->params->{'requirelogin'} ? LOGIN_REQUIRED : LOGIN_NORMAL;
    }

    # Allow templates to know that we're in a page that always requires
    # login.
    if ($type == LOGIN_REQUIRED) {
        $class->request_cache->{page_requires_login} = 1;
    }

    my $authenticated_user = $authorizer->login($type);
    
    # At this point, we now know if a real person is logged in.
    # We must now check to see if an sudo session is in progress.
    # For a session to be in progress, the following must be true:
    # 1: There must be a logged in user
    # 2: That user must be in the 'bz_sudoer' group
    # 3: There must be a valid value in the 'sudo' cookie
    # 4: A Bugzilla::User object must exist for the given cookie value
    # 5: That user must NOT be in the 'bz_sudo_protect' group
    my $sudo_cookie = $class->cgi->cookie('sudo');
    detaint_natural($sudo_cookie) if defined($sudo_cookie);
    my $sudo_target;
    $sudo_target = new Bugzilla::User($sudo_cookie) if defined($sudo_cookie);
    if (defined($authenticated_user)                 &&
        $authenticated_user->in_group('bz_sudoers')  &&
        defined($sudo_cookie)                        &&
        defined($sudo_target)                        &&
        !($sudo_target->in_group('bz_sudo_protect'))
       )
    {
        $class->set_user($sudo_target);
        $class->request_cache->{sudoer} = $authenticated_user;
        # And make sure that both users have the same Auth object,
        # since we never call Auth::login for the sudo target.
        $sudo_target->set_authorizer($authenticated_user->authorizer);

        # NOTE: If you want to do any special logging, do it here.
    }
    else {
        $class->set_user($authenticated_user);
    }

    return $class->user;
}

sub logout {
    my ($class, $option) = @_;

    # If we're not logged in, go away
    return unless $class->user->id;

    $option = LOGOUT_CURRENT unless defined $option;
    Bugzilla::Auth::Persist::Cookie->logout({type => $option});
    $class->logout_request() unless $option eq LOGOUT_KEEP_CURRENT;
}

sub logout_user {
    my ($class, $user) = @_;
    # When we're logging out another user we leave cookies alone, and
    # therefore avoid calling Bugzilla->logout() directly.
    Bugzilla::Auth::Persist::Cookie->logout({user => $user});
}

# just a compatibility front-end to logout_user that gets a user by id
sub logout_user_by_id {
    my ($class, $id) = @_;
    my $user = new Bugzilla::User($id);
    $class->logout_user($user);
}

# hack that invalidates credentials for a single request
sub logout_request {
    my $class = shift;
    delete $class->request_cache->{user};
    delete $class->request_cache->{sudoer};
    # We can't delete from $cgi->cookie, so logincookie data will remain
    # there. Don't rely on it: use Bugzilla->user->login instead!
}

sub job_queue {
    my $class = shift;
    require Bugzilla::JobQueue;
    $class->request_cache->{job_queue} ||= Bugzilla::JobQueue->new();
    return $class->request_cache->{job_queue};
}

sub dbh {
    my $class = shift;
    # If we're not connected, then we must want the main db
    $class->request_cache->{dbh} ||= $class->dbh_main;

    return $class->request_cache->{dbh};
}

sub dbh_main {
    my $class = shift;
    $class->request_cache->{dbh_main} ||= Bugzilla::DB::connect_main();
    return $class->request_cache->{dbh_main};
}

sub languages {
    my $class = shift;
    return $class->request_cache->{languages}
        if $class->request_cache->{languages};

    my @files = glob(catdir(bz_locations->{'templatedir'}, '*'));
    my @languages;
    foreach my $dir_entry (@files) {
        # It's a language directory only if it contains "default" or
        # "custom". This auto-excludes CVS directories as well.
        next unless (-d catdir($dir_entry, 'default')
                  || -d catdir($dir_entry, 'custom'));
        $dir_entry = basename($dir_entry);
        # Check for language tag format conforming to RFC 1766.
        next unless $dir_entry =~ /^[a-zA-Z]{1,8}(-[a-zA-Z]{1,8})?$/;
        push(@languages, $dir_entry);
    }
    return $class->request_cache->{languages} = \@languages;
}

sub error_mode {
    my ($class, $newval) = @_;
    if (defined $newval) {
        $class->request_cache->{error_mode} = $newval;
    }
    return $class->request_cache->{error_mode}
        || (i_am_cgi() ? ERROR_MODE_WEBPAGE : ERROR_MODE_DIE);
}

# This is used only by Bugzilla::Error to throw errors.
sub _json_server {
    my ($class, $newval) = @_;
    if (defined $newval) {
        $class->request_cache->{_json_server} = $newval;
    }
    return $class->request_cache->{_json_server};
}

sub usage_mode {
    my ($class, $newval) = @_;
    if (defined $newval) {
        if ($newval == USAGE_MODE_BROWSER) {
            $class->error_mode(ERROR_MODE_WEBPAGE);
        }
        elsif ($newval == USAGE_MODE_CMDLINE) {
            $class->error_mode(ERROR_MODE_DIE);
        }
        elsif ($newval == USAGE_MODE_XMLRPC) {
            $class->error_mode(ERROR_MODE_DIE_SOAP_FAULT);
        }
        elsif ($newval == USAGE_MODE_JSON) {
            $class->error_mode(ERROR_MODE_JSON_RPC);
        }
        elsif ($newval == USAGE_MODE_EMAIL) {
            $class->error_mode(ERROR_MODE_DIE);
        }
        else {
            ThrowCodeError('usage_mode_invalid',
                           {'invalid_usage_mode', $newval});
        }
        $class->request_cache->{usage_mode} = $newval;
    }
    return $class->request_cache->{usage_mode}
        || (i_am_cgi()? USAGE_MODE_BROWSER : USAGE_MODE_CMDLINE);
}

sub installation_mode {
    my ($class, $newval) = @_;
    ($class->request_cache->{installation_mode} = $newval) if defined $newval;
    return $class->request_cache->{installation_mode}
        || INSTALLATION_MODE_INTERACTIVE;
}

sub installation_answers {
    my ($class, $filename) = @_;
    if ($filename) {
        my $s = new Safe;
        $s->rdo($filename);

        die "Error reading $filename: $!" if $!;
        die "Error evaluating $filename: $@" if $@;

        # Now read the param back out from the sandbox
        $class->request_cache->{installation_answers} = $s->varglob('answer');
    }
    return $class->request_cache->{installation_answers} || {};
}

sub switch_to_shadow_db {
    my $class = shift;

    if (!$class->request_cache->{dbh_shadow}) {
        if ($class->params->{'shadowdb'}) {
            $class->request_cache->{dbh_shadow} = Bugzilla::DB::connect_shadow();
        } else {
            $class->request_cache->{dbh_shadow} = $class->dbh_main;
        }
    }

    $class->request_cache->{dbh} = $class->request_cache->{dbh_shadow};
    # we have to return $class->dbh instead of {dbh} as
    # {dbh_shadow} may be undefined if no shadow DB is used
    # and no connection to the main DB has been established yet.
    return $class->dbh;
}

sub switch_to_main_db {
    my $class = shift;

    $class->request_cache->{dbh} = $class->dbh_main;
    return $class->dbh_main;
}

sub get_fields {
    my $class = shift;
    my $criteria = shift;
    # This function may be called during installation, and Field::match
    # may fail at that time. so we want to return an empty list in that
    # case.
    my $fields = eval { Bugzilla::Field->match($criteria) } || [];
    return @$fields;
}

sub active_custom_fields {
    my $class = shift;
    if (!exists $class->request_cache->{active_custom_fields}) {
        $class->request_cache->{active_custom_fields} =
          Bugzilla::Field->match({ custom => 1, obsolete => 0 });
    }
    return @{$class->request_cache->{active_custom_fields}};
}

sub has_flags {
    my $class = shift;

    if (!defined $class->request_cache->{has_flags}) {
        $class->request_cache->{has_flags} = Bugzilla::Flag::has_flags();
    }
    return $class->request_cache->{has_flags};
}

sub local_timezone {
    my $class = shift;

    if (!defined $class->request_cache->{local_timezone}) {
        $class->request_cache->{local_timezone} =
          DateTime::TimeZone->new(name => 'local');
    }
    return $class->request_cache->{local_timezone};
}

# This creates the request cache for non-mod_perl installations.
# This is identical to Install::Util::_cache so that things loaded
# into Install::Util::_cache during installation can be read out
# of request_cache later in installation.
our $_request_cache = $Bugzilla::Install::Util::_cache;

sub request_cache {
    if ($ENV{MOD_PERL}) {
        require Apache2::RequestUtil;
        # Sometimes (for example, during mod_perl.pl), the request
        # object isn't available, and we should use $_request_cache instead.
        my $request = eval { Apache2::RequestUtil->request };
        return $_request_cache if !$request;
        return $request->pnotes();
    }
    return $_request_cache;
}

# Private methods

# Per-process cleanup. Note that this is a plain subroutine, not a method,
# so we don't have $class available.
sub _cleanup {
    my $main   = Bugzilla->request_cache->{dbh_main};
    my $shadow = Bugzilla->request_cache->{dbh_shadow};
    foreach my $dbh ($main, $shadow) {
        next if !$dbh;
        $dbh->bz_rollback_transaction() if $dbh->bz_in_transaction;
        $dbh->disconnect;
    }
    undef $_request_cache;
}

sub END {
    # Bugzilla.pm cannot compile in mod_perl.pl if this runs.
    _cleanup() unless $ENV{MOD_PERL};
}

init_page() if !$ENV{MOD_PERL};

1;

__END__

=head1 NAME

Bugzilla - Semi-persistent collection of various objects used by scripts
and modules

=head1 SYNOPSIS

  use Bugzilla;

  sub someModulesSub {
    Bugzilla->dbh->prepare(...);
    Bugzilla->template->process(...);
  }

=head1 DESCRIPTION

Several Bugzilla 'things' are used by a variety of modules and scripts. This
includes database handles, template objects, and so on.

This module is a singleton intended as a central place to store these objects.
This approach has several advantages:

=over 4

=item *

They're not global variables, so we don't have issues with them staying around
with mod_perl

=item *

Everything is in one central place, so it's easy to access, modify, and maintain

=item *

Code in modules can get access to these objects without having to have them
all passed from the caller, and the caller's caller, and....

=item *

We can reuse objects across requests using mod_perl where appropriate (eg
templates), whilst destroying those which are only valid for a single request
(such as the current user)

=back

Note that items accessible via this object are demand-loaded when requested.

For something to be added to this object, it should either be able to benefit
from persistence when run under mod_perl (such as the a C<template> object),
or should be something which is globally required by a large ammount of code
(such as the current C<user> object).

=head1 METHODS

Note that all C<Bugzilla> functionality is method based; use C<Bugzilla-E<gt>dbh>
rather than C<Bugzilla::dbh>. Nothing cares about this now, but don't rely on
that.

=over 4

=item C<template>

The current C<Template> object, to be used for output

=item C<template_inner>

If you ever need a L<Bugzilla::Template> object while you're already
processing a template, use this. Also use it if you want to specify
the language to use. If no argument is passed, it uses the last
language set. If the argument is "" (empty string), the language is
reset to the current one (the one used by Bugzilla->template).

=item C<cgi>

The current C<cgi> object. Note that modules should B<not> be using this in
general. Not all Bugzilla actions are cgi requests. Its useful as a convenience
method for those scripts/templates which are only use via CGI, though.

=item C<input_params>

When running under the WebService, this is a hashref containing the arguments
passed to the WebService method that was called. When running in a normal
script, this is a hashref containing the contents of the CGI parameters.

Modifying this hashref will modify the CGI parameters or the WebService
arguments (depending on what C<input_params> currently represents).

This should be used instead of L</cgi> in situations where your code
could be being called by either a normal CGI script or a WebService method,
such as during a code hook.

B<Note:> When C<input_params> represents the CGI parameters, any
parameter specified more than once (like C<foo=bar&foo=baz>) will appear
as an arrayref in the hash, but any value specified only once will appear
as a scalar. This means that even if a value I<can> appear multiple times,
if it only I<does> appear once, then it will be a scalar in C<input_params>,
not an arrayref.

=item C<user>

C<undef> if there is no currently logged in user or if the login code has not
yet been run.  If an sudo session is in progress, the C<Bugzilla::User>
corresponding to the person who is being impersonated.  If no session is in
progress, the current C<Bugzilla::User>.

=item C<set_user>

Allows you to directly set what L</user> will return. You can use this
if you want to bypass L</login> for some reason and directly "log in"
a specific L<Bugzilla::User>. Be careful with it, though!

=item C<sudoer>

C<undef> if there is no currently logged in user, the currently logged in user
is not in the I<sudoer> group, or there is no session in progress.  If an sudo
session is in progress, returns the C<Bugzilla::User> object corresponding to
the person who logged in and initiated the session.  If no session is in
progress, returns the C<Bugzilla::User> object corresponding to the currently
logged in user.

=item C<sudo_request>
This begins an sudo session for the current request.  It is meant to be 
used when a session has just started.  For normal use, sudo access should 
normally be set at login time.

=item C<login>

Logs in a user, returning a C<Bugzilla::User> object, or C<undef> if there is
no logged in user. See L<Bugzilla::Auth|Bugzilla::Auth>, and
L<Bugzilla::User|Bugzilla::User>.

=item C<page_requires_login>

If the current page always requires the user to log in (for example,
C<enter_bug.cgi> or any page called with C<?GoAheadAndLogIn=1>) then
this will return something true. Otherwise it will return false. (This is
set when you call L</login>.)

=item C<logout($option)>

Logs out the current user, which involves invalidating user sessions and
cookies. Three options are available from
L<Bugzilla::Constants|Bugzilla::Constants>: LOGOUT_CURRENT (the
default), LOGOUT_ALL or LOGOUT_KEEP_CURRENT.

=item C<logout_user($user)>

Logs out the specified user (invalidating all his sessions), taking a
Bugzilla::User instance.

=item C<logout_by_id($id)>

Logs out the user with the id specified. This is a compatibility
function to be used in callsites where there is only a userid and no
Bugzilla::User instance.

=item C<logout_request>

Essentially, causes calls to C<Bugzilla-E<gt>user> to return C<undef>. This has the
effect of logging out a user for the current request only; cookies and
database sessions are left intact.

=item C<error_mode>

Call either C<Bugzilla->error_mode(Bugzilla::Constants::ERROR_MODE_DIE)>
or C<Bugzilla->error_mode(Bugzilla::Constants::ERROR_MODE_DIE_SOAP_FAULT)> to
change this flag's default of C<Bugzilla::Constants::ERROR_MODE_WEBPAGE> and to
indicate that errors should be passed to error mode specific error handlers
rather than being sent to a browser and finished with an exit().

This is useful, for example, to keep C<eval> blocks from producing wild HTML
on errors, making it easier for you to catch them.
(Remember to reset the error mode to its previous value afterwards, though.)

C<Bugzilla->error_mode> will return the current state of this flag.

Note that C<Bugzilla->error_mode> is being called by C<Bugzilla->usage_mode> on
usage mode changes.

=item C<usage_mode>

Call either C<Bugzilla->usage_mode(Bugzilla::Constants::USAGE_MODE_CMDLINE)>
or C<Bugzilla->usage_mode(Bugzilla::Constants::USAGE_MODE_XMLRPC)> near the
beginning of your script to change this flag's default of
C<Bugzilla::Constants::USAGE_MODE_BROWSER> and to indicate that Bugzilla is
being called in a non-interactive manner.

This influences error handling because on usage mode changes, C<usage_mode>
calls C<Bugzilla->error_mode> to set an error mode which makes sense for the
usage mode.

C<Bugzilla->usage_mode> will return the current state of this flag.

=item C<installation_mode>

Determines whether or not installation should be silent. See 
L<Bugzilla::Constants> for the C<INSTALLATION_MODE> constants.

=item C<installation_answers>

Returns a hashref representing any "answers" file passed to F<checksetup.pl>,
used to automatically answer or skip prompts.

=item C<dbh>

The current database handle. See L<DBI>.

=item C<dbh_main>

The main database handle. See L<DBI>.

=item C<languages>

Currently installed languages.
Returns a reference to a list of RFC 1766 language tags of installed languages.

=item C<switch_to_shadow_db>

Switch from using the main database to using the shadow database.

=item C<switch_to_main_db>

Change the database object to refer to the main database.

=item C<params>

The current Parameters of Bugzilla, as a hashref. If C<data/params>
does not exist, then we return an empty hashref. If C<data/params>
is unreadable or is not valid perl, we C<die>.

=item C<local_timezone>

Returns the local timezone of the Bugzilla installation,
as a DateTime::TimeZone object. This detection is very time
consuming, so we cache this information for future references.

=item C<job_queue>

Returns a L<Bugzilla::JobQueue> that you can use for queueing jobs.
Will throw an error if job queueing is not correctly configured on
this Bugzilla installation.

=item C<feature>

Tells you whether or not a specific feature is enabled. For names
of features, see C<OPTIONAL_MODULES> in C<Bugzilla::Install::Requirements>.

=back
