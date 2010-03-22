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
# Contributor(s): Marc Schumann <wurblzap@gmail.com>
#                 Max Kanat-Alexander <mkanat@bugzilla.org>
#                 Mads Bondo Dydensborg <mbd@dbc.dk>
#                 Noura Elhawary <nelhawar@redhat.com>

package Bugzilla::WebService::User;

use strict;
use base qw(Bugzilla::WebService);

use Bugzilla;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::User;
use Bugzilla::Util qw(trim);
use Bugzilla::Token;
use Bugzilla::WebService::Util qw(filter validate);

# Don't need auth to login
use constant LOGIN_EXEMPT => {
    login => 1,
    offer_account_by_email => 1,
};

##############
# User Login #
##############

sub login {
    my ($self, $params) = @_;
    my $remember = $params->{remember};

    # Username and password params are required 
    foreach my $param ("login", "password") {
        defined $params->{$param} 
            || ThrowCodeError('param_required', { param => $param });
    }

    # Convert $remember from a boolean 0/1 value to a CGI-compatible one.
    if (defined($remember)) {
        $remember = $remember? 'on': '';
    }
    else {
        # Use Bugzilla's default if $remember is not supplied.
        $remember =
            Bugzilla->params->{'rememberlogin'} eq 'defaulton'? 'on': '';
    }

    # Make sure the CGI user info class works if necessary.
    my $input_params = Bugzilla->input_params;
    $input_params->{'Bugzilla_login'} =  $params->{login};
    $input_params->{'Bugzilla_password'} = $params->{password};
    $input_params->{'Bugzilla_remember'} = $remember;

    Bugzilla->login();
    return { id => $self->type('int', Bugzilla->user->id) };
}

sub logout {
    my $self = shift;
    Bugzilla->logout;
    return undef;
}

#################
# User Creation #
#################

sub offer_account_by_email {
    my $self = shift;
    my ($params) = @_;
    my $email = trim($params->{email})
        || ThrowCodeError('param_required', { param => 'email' });

    my $createexp = Bugzilla->params->{'createemailregexp'};
    if (!$createexp) {
        ThrowUserError("account_creation_disabled");
    }
    elsif ($email !~ /$createexp/) {
        ThrowUserError("account_creation_restricted");
    }

    $email = Bugzilla::User->check_login_name_for_creation($email);

    # Create and send a token for this new account.
    Bugzilla::Token::issue_new_user_account_token($email);

    return undef;
}

sub create {
    my $self = shift;
    my ($params) = @_;

    Bugzilla->user->in_group('editusers') 
        || ThrowUserError("auth_failure", { group  => "editusers",
                                            action => "add",
                                            object => "users"});

    my $email = trim($params->{email})
        || ThrowCodeError('param_required', { param => 'email' });
    my $realname = trim($params->{full_name});
    my $password = trim($params->{password}) || '*';

    my $user = Bugzilla::User->create({
        login_name    => $email,
        realname      => $realname,
        cryptpassword => $password
    });

    return { id => $self->type('int', $user->id) };
}


# function to return user information by passing either user ids or 
# login names or both together:
# $call = $rpc->call( 'User.get', { ids => [1,2,3], 
#         names => ['testusera@redhat.com', 'testuserb@redhat.com'] });
sub get {
    my ($self, $params) = validate(@_, 'names', 'ids');

    my @user_objects;
    @user_objects = map { Bugzilla::User->check($_) } @{ $params->{names} }
                    if $params->{names};

    # start filtering to remove duplicate user ids
    my %unique_users = map { $_->id => $_ } @user_objects;
    @user_objects = values %unique_users;
      
    my @users;

    # If the user is not logged in: Return an error if they passed any user ids.
    # Otherwise, return a limited amount of information based on login names.
    if (!Bugzilla->user->id){
        if ($params->{ids}){
            ThrowUserError("user_access_by_id_denied");
        }
        if ($params->{match}) {
            ThrowUserError('user_access_by_match_denied');
        }
        @users = map {filter $params, {
                     id        => $self->type('int', $_->id),
                     real_name => $self->type('string', $_->name), 
                     name      => $self->type('string', $_->login),
                 }} @user_objects;

        return { users => \@users };
    }

    my $obj_by_ids;
    $obj_by_ids = Bugzilla::User->new_from_list($params->{ids}) if $params->{ids};

    # obj_by_ids are only visible to the user if he can see 
    # the otheruser, for non visible otheruser throw an error
    foreach my $obj (@$obj_by_ids) {
        if (Bugzilla->user->can_see_user($obj)){
            if (!$unique_users{$obj->id}) {
                push (@user_objects, $obj);
                $unique_users{$obj->id} = $obj;
            }
        }
        else {
            ThrowUserError('auth_failure', {reason => "not_visible",
                                            action => "access",
                                            object => "user",
                                            userid => $obj->id});
        }
    }
    
    # User Matching
    my $limit;
    if ($params->{'maxusermatches'}) {
        $limit = $params->{'maxusermatches'} + 1;
    }
    foreach my $match_string (@{ $params->{'match'} || [] }) {
        my $matched = Bugzilla::User::match($match_string, $limit);
        foreach my $user (@$matched) {
            if (!$unique_users{$user->id}) {
                push(@user_objects, $user);
                $unique_users{$user->id} = $user;
            }
        }
    }
    
    if (Bugzilla->user->in_group('editusers')) {
        @users =
            map {filter $params, {
                id        => $self->type('int', $_->id),
                real_name => $self->type('string', $_->name),
                name      => $self->type('string', $_->login),
                email     => $self->type('string', $_->email),
                can_login => $self->type('boolean', $_->is_disabled ? 0 : 1),
                email_enabled     => $self->type('boolean', $_->email_enabled),
                login_denied_text => $self->type('string', $_->disabledtext),
            }} @user_objects;

    }    
    else {
        @users =
            map {filter $params, {
                id        => $self->type('int', $_->id),
                real_name => $self->type('string', $_->name),
                name      => $self->type('string', $_->login),
                email     => $self->type('string', $_->email),
                can_login => $self->type('boolean', $_->is_disabled ? 0 : 1),
            }} @user_objects;
    }

    return { users => \@users };
}

1;

__END__

=head1 NAME

Bugzilla::Webservice::User - The User Account and Login API

=head1 DESCRIPTION

This part of the Bugzilla API allows you to create User Accounts and
log in/out using an existing account.

=head1 METHODS

See L<Bugzilla::WebService> for a description of how parameters are passed,
and what B<STABLE>, B<UNSTABLE>, and B<EXPERIMENTAL> mean.

=head2 Logging In and Out

=over

=item C<login> 

B<STABLE>

=over

=item B<Description>

Logging in, with a username and password, is required for many
Bugzilla installations, in order to search for bugs, post new bugs,
etc. This method logs in an user.

=item B<Params>

=over

=item C<login> (string) - The user's login name. 

=item C<password> (string) - The user's password.

=item C<remember> (bool) B<Optional> - if the cookies returned by the
call to login should expire with the session or not.  In order for
this option to have effect the Bugzilla server must be configured to
allow the user to set this option - the Bugzilla parameter
I<rememberlogin> must be set to "defaulton" or
"defaultoff". Addionally, the client application must implement
management of cookies across sessions.

=back

=item B<Returns>

On success, a hash containing one item, C<id>, the numeric id of the
user that was logged in.  A set of http cookies is also sent with the
response.  These cookies must be sent along with any future requests
to the webservice, for the duration of the session.

=item B<Errors>

=over

=item 300 (Invalid Username or Password)

The username does not exist, or the password is wrong.

=item 301 (Account Disabled)

The account has been disabled.  A reason may be specified with the
error.

=item 50 (Param Required)

A login or password parameter was not provided.

=back

=back

=item C<logout> 

B<STABLE>

=over

=item B<Description>

Log out the user. Does nothing if there is no user logged in.

=item B<Params> (none)

=item B<Returns> (nothing)

=item B<Errors> (none)

=back

=back

=head2 Account Creation

=over

=item C<offer_account_by_email> 

B<STABLE>

=over

=item B<Description>

Sends an email to the user, offering to create an account.  The user
will have to click on a URL in the email, and choose their password
and real name.

This is the recommended way to create a Bugzilla account.

=item B<Param>

=over

=item C<email> (string) - the email to send the offer to.

=back

=item B<Returns> (nothing)

=item B<Errors>

=over

=item 500 (Illegal Email Address)

This Bugzilla does not allow you to create accounts with the format of
email address you specified. Account creation may be entirely disabled.

=item 501 (Account Already Exists)

An account with that email address already exists in Bugzilla.

=back

=back

=item C<create> 

B<STABLE>

=over

=item B<Description>

Creates a user account directly in Bugzilla, password and all.
Instead of this, you should use L</offer_account_by_email> when
possible, because that makes sure that the email address specified can
actually receive an email. This function does not check that.

You must be logged in and have the C<editusers> privilege in order to
call this function.

=item B<Params>

=over

=item C<email> (string) - The email address for the new user.

=item C<full_name> (string) B<Optional> - The user's full name. Will
be set to empty if not specified.

=item C<password> (string) B<Optional> - The password for the new user
account, in plain text.  It will be stripped of leading and trailing
whitespace.  If blank or not specified, the newly created account will
exist in Bugzilla, but will not be allowed to log in using DB
authentication until a password is set either by the user (through
resetting their password) or by the administrator.

=back

=item B<Returns>

A hash containing one item, C<id>, the numeric id of the user that was
created.

=item B<Errors>

The same as L</offer_account_by_email>. If a password is specified,
the function may also throw:

=over

=item 502 (Password Too Short)

The password specified is too short. (Usually, this means the
password is under three characters.)

=back

=item B<History>

=over

=item Error 503 (Password Too Long) removed in Bugzilla B<3.6>.

=back

=back

=back

=head2 User Info

=over

=item C<get> 

B<STABLE>

=over

=item B<Description>

Gets information about user accounts in Bugzilla.

=item B<Params>

B<Note>: At least one of C<ids>, C<names>, or C<match> must be specified.

B<Note>: Users will not be returned more than once, so even if a user 
is matched by more than one argument, only one user will be returned.

In addition to the parameters below, this method also accepts the
standard L<include_fields|Bugzilla::WebService/include_fields> and
L<exclude_fields|Bugzilla::WebService/exclude_fields> arguments.

=over

=item C<ids> (array) 

An array of integers, representing user ids.

Logged-out users cannot pass this parameter to this function. If they try,
they will get an error. Logged-in users will get an error if they specify
the id of a user they cannot see.

=item C<names> (array) - An array of login names (strings).

=item C<match> (array)

An array of strings. This works just like "user matching" in
Bugzilla itself. Users will be returned whose real name or login name
contains any one of the specified strings. Users that you cannot see will
not be included in the returned list.

Some Bugzilla installations have user-matching turned off, in which
case you will only be returned exact matches.

Most installations have a limit on how many matches are returned for
each string, which defaults to 1000 but can be changed by the Bugzilla
administrator.

Logged-out users cannot use this argument, and an error will be thrown
if they try. (This is to make it harder for spammers to harvest email
addresses from Bugzilla, and also to enforce the user visibility
restrictions that are implemented on some Bugzillas.)

=back

=item B<Returns> 

A hash containing one item, C<users>, that is an array of
hashes. Each hash describes a user, and has the following items:

=over

=item id

C<int> The unique integer ID that Bugzilla uses to represent this user. 
Even if the user's login name changes, this will not change.

=item real_name

C<string> The actual name of the user. May be blank.

=item email

C<string> The email address of the user.

=item name

C<string> The login name of the user. Note that in some situations this is 
different than their email.

=item can_login

C<boolean> A boolean value to indicate if the user can login into bugzilla. 

=item email_enabled

C<boolean> A boolean value to indicate if bug-related mail will be sent
to the user or not.

=item login_denied_text

C<string> A text field that holds the reason for disabling a user from logging
into bugzilla, if empty then the user account is enabled. Otherwise it is 
disabled/closed.

B<Note>: If you are not logged in to Bugzilla when you call this function, you
will only be returned the C<id>, C<name>, and C<real_name> items. If you are
logged in and not in editusers group, you will only be returned the C<id>, C<name>, 
C<real_name>, C<email>, and C<can_login> items.

=back

=item B<Errors>

=over

=item 51 (Bad Login Name)

You passed an invalid login name in the "names" array.

=item 304 (Authorization Required)

You are logged in, but you are not authorized to see one of the users you
wanted to get information about by user id.

=item 505 (User Access By Id or User-Matching Denied)

Logged-out users cannot use the "ids" or "match" arguments to this 
function.

=back

=item B<History>

=over

=item Added in Bugzilla B<3.4>.

=back

=back

=back
