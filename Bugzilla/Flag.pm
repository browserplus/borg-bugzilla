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
# Contributor(s): Myk Melez <myk@mozilla.org>
#                 Jouni Heikniemi <jouni@heikniemi.net>
#                 Frédéric Buclin <LpSolit@gmail.com>

use strict;

package Bugzilla::Flag;

=head1 NAME

Bugzilla::Flag - A module to deal with Bugzilla flag values.

=head1 SYNOPSIS

Flag.pm provides an interface to flags as stored in Bugzilla.
See below for more information.

=head1 NOTES

=over

=item *

Import relevant functions from that script.

=item *

Use of private functions / variables outside this module may lead to
unexpected results after an upgrade.  Please avoid using private
functions in other files/modules.  Private functions are functions
whose names start with _ or a re specifically noted as being private.

=back

=cut

use Scalar::Util qw(blessed);

use Bugzilla::FlagType;
use Bugzilla::Hook;
use Bugzilla::User;
use Bugzilla::Util;
use Bugzilla::Error;
use Bugzilla::Mailer;
use Bugzilla::Constants;
use Bugzilla::Field;

use base qw(Bugzilla::Object Exporter);
@Bugzilla::Flag::EXPORT = qw(SKIP_REQUESTEE_ON_ERROR);

###############################
####    Initialization     ####
###############################

use constant DB_TABLE => 'flags';
use constant LIST_ORDER => 'id';

use constant SKIP_REQUESTEE_ON_ERROR => 1;

use constant DB_COLUMNS => qw(
    id
    type_id
    bug_id
    attach_id
    requestee_id
    setter_id
    status
);

use constant REQUIRED_CREATE_FIELDS => qw(
    attach_id
    bug_id
    setter_id
    status
    type_id
);

use constant UPDATE_COLUMNS => qw(
    requestee_id
    setter_id
    status
    type_id
);

use constant VALIDATORS => {
};

use constant UPDATE_VALIDATORS => {
    setter => \&_check_setter,
    status => \&_check_status,
};

###############################
####      Accessors      ######
###############################

=head2 METHODS

=over

=item C<id>

Returns the ID of the flag.

=item C<name>

Returns the name of the flagtype the flag belongs to.

=item C<bug_id>

Returns the ID of the bug this flag belongs to.

=item C<attach_id>

Returns the ID of the attachment this flag belongs to, if any.

=item C<status>

Returns the status '+', '-', '?' of the flag.

=back

=cut

sub id           { return $_[0]->{'id'};           }
sub name         { return $_[0]->type->name;       }
sub type_id      { return $_[0]->{'type_id'};      }
sub bug_id       { return $_[0]->{'bug_id'};       }
sub attach_id    { return $_[0]->{'attach_id'};    }
sub status       { return $_[0]->{'status'};       }
sub setter_id    { return $_[0]->{'setter_id'};    }
sub requestee_id { return $_[0]->{'requestee_id'}; }

###############################
####       Methods         ####
###############################

=pod

=over

=item C<type>

Returns the type of the flag, as a Bugzilla::FlagType object.

=item C<setter>

Returns the user who set the flag, as a Bugzilla::User object.

=item C<requestee>

Returns the user who has been requested to set the flag, as a
Bugzilla::User object.

=item C<attachment>

Returns the attachment object the flag belongs to if the flag
is an attachment flag, else undefined.

=back

=cut

sub type {
    my $self = shift;

    $self->{'type'} ||= new Bugzilla::FlagType($self->{'type_id'});
    return $self->{'type'};
}

sub setter {
    my $self = shift;

    $self->{'setter'} ||= new Bugzilla::User($self->{'setter_id'});
    return $self->{'setter'};
}

sub requestee {
    my $self = shift;

    if (!defined $self->{'requestee'} && $self->{'requestee_id'}) {
        $self->{'requestee'} = new Bugzilla::User($self->{'requestee_id'});
    }
    return $self->{'requestee'};
}

sub attachment {
    my $self = shift;
    return undef unless $self->attach_id;

    require Bugzilla::Attachment;
    $self->{'attachment'} ||= new Bugzilla::Attachment($self->attach_id);
    return $self->{'attachment'};
}

sub bug {
    my $self = shift;

    require Bugzilla::Bug;
    $self->{'bug'} ||= new Bugzilla::Bug($self->bug_id);
    return $self->{'bug'};
}

################################
## Searching/Retrieving Flags ##
################################

=pod

=over

=item C<has_flags>

Returns 1 if at least one flag exists in the DB, else 0. This subroutine
is mainly used to decide to display the "(My )Requests" link in the footer.

=back

=cut

sub has_flags {
    my $dbh = Bugzilla->dbh;

    my $has_flags = $dbh->selectrow_array('SELECT 1 FROM flags ' . $dbh->sql_limit(1));
    return $has_flags || 0;
}

=pod

=over

=item C<match($criteria)>

Queries the database for flags matching the given criteria
(specified as a hash of field names and their matching values)
and returns an array of matching records.

=back

=cut

sub match {
    my $class = shift;
    my ($criteria) = @_;

    # If the caller specified only bug or attachment flags,
    # limit the query to those kinds of flags.
    if (my $type = delete $criteria->{'target_type'}) {
        if ($type eq 'bug') {
            $criteria->{'attach_id'} = IS_NULL;
        }
        elsif (!defined $criteria->{'attach_id'}) {
            $criteria->{'attach_id'} = NOT_NULL;
        }
    }
    # Flag->snapshot() calls Flag->match() with bug_id and attach_id
    # as hash keys, even if attach_id is undefined.
    if (exists $criteria->{'attach_id'} && !defined $criteria->{'attach_id'}) {
        $criteria->{'attach_id'} = IS_NULL;
    }

    return $class->SUPER::match(@_);
}

=pod

=over

=item C<count($criteria)>

Queries the database for flags matching the given criteria
(specified as a hash of field names and their matching values)
and returns an array of matching records.

=back

=cut

sub count {
    my $class = shift;
    return scalar @{$class->match(@_)};
}

######################################################################
# Creating and Modifying
######################################################################

sub set_flag {
    my ($class, $obj, $params) = @_;

    my ($bug, $attachment);
    if (blessed($obj) && $obj->isa('Bugzilla::Attachment')) {
        $attachment = $obj;
        $bug = $attachment->bug;
    }
    elsif (blessed($obj) && $obj->isa('Bugzilla::Bug')) {
        $bug = $obj;
    }
    else {
        ThrowCodeError('flag_unexpected_object', { 'caller' => ref $obj });
    }

    # Update (or delete) an existing flag.
    if ($params->{id}) {
        my $flag = $class->check({ id => $params->{id} });

        # Security check: make sure the flag belongs to the bug/attachment.
        # We don't check that the user editing the flag can see
        # the bug/attachment. That's the job of the caller.
        ($attachment && $flag->attach_id && $attachment->id == $flag->attach_id)
          || (!$attachment && !$flag->attach_id && $bug->id == $flag->bug_id)
          || ThrowCodeError('invalid_flag_association',
                            { bug_id    => $bug->id,
                              attach_id => $attachment ? $attachment->id : undef });

        # Extract the current flag object from the object.
        my ($obj_flagtype) = grep { $_->id == $flag->type_id } @{$obj->flag_types};
        # If no flagtype can be found for this flag, this means the bug is being
        # moved into a product/component where the flag is no longer valid.
        # So either we can attach the flag to another flagtype having the same
        # name, or we remove the flag.
        if (!$obj_flagtype) {
            my $success = $flag->retarget($obj);
            return unless $success;

            ($obj_flagtype) = grep { $_->id == $flag->type_id } @{$obj->flag_types};
            push(@{$obj_flagtype->{flags}}, $flag);
        }
        my ($obj_flag) = grep { $_->id == $flag->id } @{$obj_flagtype->{flags}};
        # If the flag has the correct type but cannot be found above, this means
        # the flag is going to be removed (e.g. because this is a pending request
        # and the attachment is being marked as obsolete).
        return unless $obj_flag;

        $class->_validate($obj_flag, $obj_flagtype, $params, $bug, $attachment);
    }
    # Create a new flag.
    elsif ($params->{type_id}) {
        # Don't bother validating types the user didn't touch.
        return if $params->{status} eq 'X';

        my $flagtype = Bugzilla::FlagType->check({ id => $params->{type_id} });
        # Security check: make sure the flag type belongs to the bug/attachment.
        ($attachment && $flagtype->target_type eq 'attachment'
          && scalar(grep { $_->id == $flagtype->id } @{$attachment->flag_types}))
          || (!$attachment && $flagtype->target_type eq 'bug'
                && scalar(grep { $_->id == $flagtype->id } @{$bug->flag_types}))
          || ThrowCodeError('invalid_flag_association',
                            { bug_id    => $bug->id,
                              attach_id => $attachment ? $attachment->id : undef });

        # Make sure the flag type is active.
        $flagtype->is_active
          || ThrowCodeError('flag_type_inactive', { type => $flagtype->name });

        # Extract the current flagtype object from the object.
        my ($obj_flagtype) = grep { $_->id == $flagtype->id } @{$obj->flag_types};

        # We cannot create a new flag if there is already one and this
        # flag type is not multiplicable.
        if (!$flagtype->is_multiplicable) {
            if (scalar @{$obj_flagtype->{flags}}) {
                ThrowUserError('flag_type_not_multiplicable', { type => $flagtype });
            }
        }

        $class->_validate(undef, $obj_flagtype, $params, $bug, $attachment);
    }
    else {
        ThrowCodeError('param_required', { function => $class . '->set_flag',
                                           param    => 'id/type_id' });
    }
}

sub _validate {
    my ($class, $flag, $flag_type, $params, $bug, $attachment) = @_;

    # If it's a new flag, let's create it now.
    my $obj_flag = $flag || bless({ type_id   => $flag_type->id,
                                    status    => '',
                                    bug_id    => $bug->id,
                                    attach_id => $attachment ?
                                                   $attachment->id : undef},
                                    $class);

    my $old_status = $obj_flag->status;
    my $old_requestee_id = $obj_flag->requestee_id;

    $obj_flag->_set_status($params->{status});
    $obj_flag->_set_requestee($params->{requestee}, $attachment, $params->{skip_roe});

    # The setter field MUST NOT be updated if neither the status
    # nor the requestee fields changed.
    if (($obj_flag->status ne $old_status)
        # The requestee ID can be undefined.
        || (($obj_flag->requestee_id || 0) != ($old_requestee_id || 0)))
    {
        $obj_flag->_set_setter($params->{setter});
    }

    # If the flag is deleted, remove it from the list.
    if ($obj_flag->status eq 'X') {
        @{$flag_type->{flags}} = grep { $_->id != $obj_flag->id } @{$flag_type->{flags}};
    }
    # Add the newly created flag to the list.
    elsif (!$obj_flag->id) {
        push(@{$flag_type->{flags}}, $obj_flag);
    }
}

=pod

=over

=item C<create($flag, $timestamp)>

Creates a flag record in the database.

=back

=cut

sub create {
    my ($class, $flag, $timestamp) = @_;
    $timestamp ||= Bugzilla->dbh->selectrow_array('SELECT NOW()');

    my $params = {};
    my @columns = grep { $_ ne 'id' } $class->DB_COLUMNS;
    $params->{$_} = $flag->{$_} foreach @columns;

    $params->{creation_date} = $params->{modification_date} = $timestamp;
    $flag = $class->SUPER::create($params);
    return $flag;
}

sub update {
    my $self = shift;
    my $dbh = Bugzilla->dbh;
    my $timestamp = shift || $dbh->selectrow_array('SELECT NOW()');

    my $changes = $self->SUPER::update(@_);

    if (scalar(keys %$changes)) {
        $dbh->do('UPDATE flags SET modification_date = ? WHERE id = ?',
                 undef, ($timestamp, $self->id));
    }
    return $changes;
}

sub snapshot {
    my ($class, $flags) = @_;

    my @summaries;
    foreach my $flag (@$flags) {
        my $summary = $flag->setter->nick . ':' . $flag->type->name . $flag->status;
        $summary .= "(" . $flag->requestee->login . ")" if $flag->requestee;
        push(@summaries, $summary);
    }
    return @summaries;
}

sub update_activity {
    my ($class, $old_summaries, $new_summaries) = @_;

    my ($removed, $added) = diff_arrays($old_summaries, $new_summaries);
    if (scalar @$removed || scalar @$added) {
        # Remove flag requester/setter information
        foreach (@$removed, @$added) { s/^[^:]+:// }

        $removed = join(", ", @$removed);
        $added = join(", ", @$added);
        return ($removed, $added);
    }
    return ();
}

sub update_flags {
    my ($class, $self, $old_self, $timestamp) = @_;

    my @old_summaries = $class->snapshot($old_self->flags);
    my %old_flags = map { $_->id => $_ } @{$old_self->flags};

    foreach my $new_flag (@{$self->flags}) {
        if (!$new_flag->id) {
            # This is a new flag.
            my $flag = $class->create($new_flag, $timestamp);
            $new_flag->{id} = $flag->id;
            $class->notify($new_flag, undef, $self);
        }
        else {
            my $changes = $new_flag->update($timestamp);
            if (scalar(keys %$changes)) {
                $class->notify($new_flag, $old_flags{$new_flag->id}, $self);
            }
            delete $old_flags{$new_flag->id};
        }
    }
    # These flags have been deleted.
    foreach my $old_flag (values %old_flags) {
        $class->notify(undef, $old_flag, $self);
        $old_flag->remove_from_db();
    }

    # If the bug has been moved into another product or component,
    # we must also take care of attachment flags which are no longer valid,
    # as well as all bug flags which haven't been forgotten above.
    if ($self->isa('Bugzilla::Bug')
        && ($self->{_old_product_name} || $self->{_old_component_name}))
    {
        my @removed = $class->force_cleanup($self);
        push(@old_summaries, @removed);
    }

    my @new_summaries = $class->snapshot($self->flags);
    my @changes = $class->update_activity(\@old_summaries, \@new_summaries);

    Bugzilla::Hook::process('flag_end_of_update', { object    => $self,
                                                    timestamp => $timestamp,
                                                    old_flags => \@old_summaries,
                                                    new_flags => \@new_summaries,
                                                  });
    return @changes;
}

sub retarget {
    my ($self, $obj) = @_;

    my @flagtypes = grep { $_->name eq $self->type->name } @{$obj->flag_types};

    my $success = 0;
    foreach my $flagtype (@flagtypes) {
        next if !$flagtype->is_active;
        next if (!$flagtype->is_multiplicable && scalar @{$flagtype->{flags}});

        $self->{type_id} = $flagtype->id;
        delete $self->{type};
        $success = 1;
        last;
    }
    return $success;
}

# In case the bug's product/component has changed, clear flags that are
# no longer valid.
sub force_cleanup {
    my ($class, $bug) = @_;
    my $dbh = Bugzilla->dbh;

    my $flag_ids = $dbh->selectcol_arrayref(
        'SELECT DISTINCT flags.id
           FROM flags
          INNER JOIN bugs
                ON flags.bug_id = bugs.bug_id
           LEFT JOIN flaginclusions AS i
                ON flags.type_id = i.type_id
                AND (bugs.product_id = i.product_id OR i.product_id IS NULL)
                AND (bugs.component_id = i.component_id OR i.component_id IS NULL)
          WHERE bugs.bug_id = ? AND i.type_id IS NULL',
         undef, $bug->id);

    my @removed = $class->force_retarget($flag_ids, $bug);

    $flag_ids = $dbh->selectcol_arrayref(
        'SELECT DISTINCT flags.id
           FROM flags, bugs, flagexclusions e
          WHERE bugs.bug_id = ?
                AND flags.bug_id = bugs.bug_id
                AND flags.type_id = e.type_id
                AND (bugs.product_id = e.product_id OR e.product_id IS NULL)
                AND (bugs.component_id = e.component_id OR e.component_id IS NULL)',
         undef, $bug->id);

    push(@removed , $class->force_retarget($flag_ids, $bug));
    return @removed;
}

sub force_retarget {
    my ($class, $flag_ids, $bug) = @_;
    my $dbh = Bugzilla->dbh;

    my $flags = $class->new_from_list($flag_ids);
    my @removed;
    foreach my $flag (@$flags) {
        # $bug is undefined when e.g. editing inclusion and exclusion lists.
        my $obj = $flag->attachment || $bug || $flag->bug;
        my $is_retargetted = $flag->retarget($obj);
        if ($is_retargetted) {
            $dbh->do('UPDATE flags SET type_id = ? WHERE id = ?',
                     undef, ($flag->type_id, $flag->id));
        }
        else {
            # Track deleted attachment flags.
            push(@removed, $class->snapshot([$flag])) if $flag->attach_id;
            $class->notify(undef, $flag, $bug || $flag->bug);
            $flag->remove_from_db();
        }
    }
    return @removed;
}

###############################
####      Validators     ######
###############################

sub _set_requestee {
    my ($self, $requestee, $attachment, $skip_requestee_on_error) = @_;

    # Used internally to check if the requestee is retargetting the request.
    $self->{_old_requestee_id} = $self->requestee ? $self->requestee->id : 0;
    $self->{requestee} =
      $self->_check_requestee($requestee, $attachment, $skip_requestee_on_error);

    $self->{requestee_id} =
      $self->{requestee} ? $self->{requestee}->id : undef;
}

sub _set_setter {
    my ($self, $setter) = @_;

    $self->set('setter', $setter);
    $self->{setter_id} = $self->setter->id;
}

sub _set_status {
    my ($self, $status) = @_;

    # Store the old flag status. It's needed by _check_setter().
    $self->{_old_status} = $self->status;
    $self->set('status', $status);
}

sub _check_requestee {
    my ($self, $requestee, $attachment, $skip_requestee_on_error) = @_;

    # If the flag status is not "?", then no requestee can be defined.
    return undef if ($self->status ne '?');

    # Store this value before updating the flag object.
    my $old_requestee = $self->requestee ? $self->requestee->login : '';

    if ($self->status eq '?' && $requestee) {
        $requestee = Bugzilla::User->check($requestee);
    }
    else {
        undef $requestee;
    }

    if ($requestee && $requestee->login ne $old_requestee) {
        # Make sure the user didn't specify a requestee unless the flag
        # is specifically requestable. For existing flags, if the requestee
        # was set before the flag became specifically unrequestable, the
        # user can either remove him or leave him alone.
        ThrowCodeError('flag_requestee_disabled', { type => $self->type })
          if !$self->type->is_requesteeble;

        # Make sure the requestee can see the bug.
        # Note that can_see_bug() will query the DB, so if the bug
        # is being added/removed from some groups and these changes
        # haven't been committed to the DB yet, they won't be taken
        # into account here. In this case, old restrictions matters.
        if (!$requestee->can_see_bug($self->bug_id)) {
            if ($skip_requestee_on_error) {
                undef $requestee;
            }
            else {
                ThrowUserError('flag_requestee_unauthorized',
                               { flag_type  => $self->type,
                                 requestee  => $requestee,
                                 bug_id     => $self->bug_id,
                                 attach_id  => $self->attach_id });
            }
        }
        # Make sure the requestee can see the private attachment.
        elsif ($self->attach_id && $attachment->isprivate && !$requestee->is_insider) {
            if ($skip_requestee_on_error) {
                undef $requestee;
            }
            else {
                ThrowUserError('flag_requestee_unauthorized_attachment',
                               { flag_type  => $self->type,
                                 requestee  => $requestee,
                                 bug_id     => $self->bug_id,
                                 attach_id  => $self->attach_id });
            }
        }
        # Make sure the user is allowed to set the flag.
        elsif (!$requestee->can_set_flag($self->type)) {
            if ($skip_requestee_on_error) {
                undef $requestee;
            }
            else {
                ThrowUserError('flag_requestee_needs_privs',
                               {'requestee' => $requestee,
                                'flagtype'  => $self->type});
            }
        }
    }
    return $requestee;
}

sub _check_setter {
    my ($self, $setter) = @_;

    # By default, the currently logged in user is the setter.
    $setter ||= Bugzilla->user;
    (blessed($setter) && $setter->isa('Bugzilla::User') && $setter->id)
      || ThrowCodeError('invalid_user');

    # set_status() has already been called. So this refers
    # to the new flag status.
    my $status = $self->status;

    # Make sure the user is authorized to modify flags, see bug 180879:
    # - The flag exists and is unchanged.
    # - The flag setter can unset flag.
    # - Users in the request_group can clear pending requests and set flags
    #   and can rerequest set flags.
    # - Users in the grant_group can set/clear flags, including "+" and "-".
    unless (($status eq $self->{_old_status})
            || ($status eq 'X' && $setter->id == Bugzilla->user->id)
            || (($status eq 'X' || $status eq '?')
                && $setter->can_request_flag($self->type))
            || $setter->can_set_flag($self->type))
    {
        ThrowUserError('flag_update_denied',
                        { name       => $self->type->name,
                          status     => $status,
                          old_status => $self->{_old_status} });
    }

    # If the requester is retargetting the request, we don't
    # update the setter, so that the setter gets the notification.
    if ($status eq '?' && $self->{_old_requestee_id} == $setter->id) {
        return $self->setter;
    }
    return $setter;
}

sub _check_status {
    my ($self, $status) = @_;

    # - Make sure the status is valid.
    # - Make sure the user didn't request the flag unless it's requestable.
    #   If the flag existed and was requested before it became unrequestable,
    #   leave it as is.
    if (!grep($status eq $_ , qw(X + - ?))
        || ($status eq '?' && $self->status ne '?' && !$self->type->is_requestable))
    {
        ThrowCodeError('flag_status_invalid', { id     => $self->id,
                                                status => $status });
    }
    return $status;
}

######################################################################
# Utility Functions
######################################################################

=pod

=over

=item C<extract_flags_from_cgi($bug, $attachment, $hr_vars)>

Checks whether or not there are new flags to create and returns an
array of hashes. This array is then passed to Flag::create().

=back

=cut

sub extract_flags_from_cgi {
    my ($class, $bug, $attachment, $vars, $skip) = @_;
    my $cgi = Bugzilla->cgi;

    my $match_status = Bugzilla::User::match_field({
        '^requestee(_type)?-(\d+)$' => { 'type' => 'multi' },
    }, undef, $skip);

    $vars->{'match_field'} = 'requestee';
    if ($match_status == USER_MATCH_FAILED) {
        $vars->{'message'} = 'user_match_failed';
    }
    elsif ($match_status == USER_MATCH_MULTIPLE) {
        $vars->{'message'} = 'user_match_multiple';
    }

    # Extract a list of flag type IDs from field names.
    my @flagtype_ids = map(/^flag_type-(\d+)$/ ? $1 : (), $cgi->param());
    @flagtype_ids = grep($cgi->param("flag_type-$_") ne 'X', @flagtype_ids);

    # Extract a list of existing flag IDs.
    my @flag_ids = map(/^flag-(\d+)$/ ? $1 : (), $cgi->param());

    return () if (!scalar(@flagtype_ids) && !scalar(@flag_ids));

    my (@new_flags, @flags);
    foreach my $flag_id (@flag_ids) {
        my $flag = $class->new($flag_id);
        # If the flag no longer exists, ignore it.
        next unless $flag;

        my $status = $cgi->param("flag-$flag_id");

        # If the user entered more than one name into the requestee field
        # (i.e. they want more than one person to set the flag) we can reuse
        # the existing flag for the first person (who may well be the existing
        # requestee), but we have to create new flags for each additional requestee.
        my @requestees = $cgi->param("requestee-$flag_id");
        my $requestee_email;
        if ($status eq "?"
            && scalar(@requestees) > 1
            && $flag->type->is_multiplicable)
        {
            # The first person, for which we'll reuse the existing flag.
            $requestee_email = shift(@requestees);

            # Create new flags like the existing one for each additional person.
            foreach my $login (@requestees) {
                push(@new_flags, { type_id   => $flag->type_id,
                                   status    => "?",
                                   requestee => $login,
                                   skip_roe  => $skip });
            }
        }
        elsif ($status eq "?" && scalar(@requestees)) {
            # If there are several requestees and the flag type is not multiplicable,
            # this will fail. But that's the job of the validator to complain. All
            # we do here is to extract and convert data from the CGI.
            $requestee_email = trim($cgi->param("requestee-$flag_id") || '');
        }

        push(@flags, { id        => $flag_id,
                       status    => $status,
                       requestee => $requestee_email,
                       skip_roe  => $skip });
    }

    # Get a list of active flag types available for this product/component.
    my $flag_types = Bugzilla::FlagType::match(
        { 'product_id'   => $bug->{'product_id'},
          'component_id' => $bug->{'component_id'},
          'is_active'    => 1 });

    foreach my $flagtype_id (@flagtype_ids) {
        # Checks if there are unexpected flags for the product/component.
        if (!scalar(grep { $_->id == $flagtype_id } @$flag_types)) {
            $vars->{'message'} = 'unexpected_flag_types';
            last;
        }
    }

    foreach my $flag_type (@$flag_types) {
        my $type_id = $flag_type->id;

        # Bug flags are only valid for bugs, and attachment flags are
        # only valid for attachments. So don't mix both.
        next unless ($flag_type->target_type eq 'bug' xor $attachment);

        # We are only interested in flags the user tries to create.
        next unless scalar(grep { $_ == $type_id } @flagtype_ids);

        # Get the number of flags of this type already set for this target.
        my $has_flags = $class->count(
            { 'type_id'     => $type_id,
              'target_type' => $attachment ? 'attachment' : 'bug',
              'bug_id'      => $bug->bug_id,
              'attach_id'   => $attachment ? $attachment->id : undef });

        # Do not create a new flag of this type if this flag type is
        # not multiplicable and already has a flag set.
        next if (!$flag_type->is_multiplicable && $has_flags);

        my $status = $cgi->param("flag_type-$type_id");
        trick_taint($status);

        my @logins = $cgi->param("requestee_type-$type_id");
        if ($status eq "?" && scalar(@logins)) {
            foreach my $login (@logins) {
                push (@new_flags, { type_id   => $type_id,
                                    status    => $status,
                                    requestee => $login,
                                    skip_roe  => $skip });
                last unless $flag_type->is_multiplicable;
            }
        }
        else {
            push (@new_flags, { type_id => $type_id,
                                status  => $status });
        }
    }

    # Return the list of flags to update and/or to create.
    return (\@flags, \@new_flags);
}

=pod

=over

=item C<notify($flag, $bug, $attachment)>

Sends an email notification about a flag being created, fulfilled
or deleted.

=back

=cut

sub notify {
    my ($class, $flag, $old_flag, $obj) = @_;

    my ($bug, $attachment);
    if (blessed($obj) && $obj->isa('Bugzilla::Attachment')) {
        $attachment = $obj;
        $bug = $attachment->bug;
    }
    elsif (blessed($obj) && $obj->isa('Bugzilla::Bug')) {
        $bug = $obj;
    }
    else {
        # Not a good time to throw an error.
        return;
    }

    my $addressee;
    # If the flag is set to '?', maybe the requestee wants a notification.
    if ($flag && $flag->requestee_id
        && (!$old_flag || ($old_flag->requestee_id || 0) != $flag->requestee_id))
    {
        if ($flag->requestee->wants_mail([EVT_FLAG_REQUESTED])) {
            $addressee = $flag->requestee;
        }
    }
    elsif ($old_flag && $old_flag->status eq '?'
           && (!$flag || $flag->status ne '?'))
    {
        if ($old_flag->setter->wants_mail([EVT_REQUESTED_FLAG])) {
            $addressee = $old_flag->setter;
        }
    }

    my $cc_list = $flag ? $flag->type->cc_list : $old_flag->type->cc_list;
    # Is there someone to notify?
    return unless ($addressee || $cc_list);

    # If the target bug is restricted to one or more groups, then we need
    # to make sure we don't send email about it to unauthorized users
    # on the request type's CC: list, so we have to trawl the list for users
    # not in those groups or email addresses that don't have an account.
    my @bug_in_groups = grep {$_->{'ison'} || $_->{'mandatory'}} @{$bug->groups};
    my $attachment_is_private = $attachment ? $attachment->isprivate : undef;

    my %recipients;
    foreach my $cc (split(/[, ]+/, $cc_list)) {
        my $ccuser = new Bugzilla::User({ name => $cc });
        next if (scalar(@bug_in_groups) && (!$ccuser || !$ccuser->can_see_bug($bug->bug_id)));
        next if $attachment_is_private && (!$ccuser || !$ccuser->is_insider);
        # Prevent duplicated entries due to case sensitivity.
        $cc = $ccuser ? $ccuser->email : $cc;
        $recipients{$cc} = $ccuser;
    }

    # Only notify if the addressee is allowed to receive the email.
    if ($addressee && $addressee->email_enabled) {
        $recipients{$addressee->email} = $addressee;
    }
    # Process and send notification for each recipient.
    # If there are users in the CC list who don't have an account,
    # use the default language for email notifications.
    my $default_lang;
    if (grep { !$_ } values %recipients) {
        $default_lang = Bugzilla::User->new()->settings->{'lang'}->{'value'};
    }

    foreach my $to (keys %recipients) {
        # Add threadingmarker to allow flag notification emails to be the
        # threaded similar to normal bug change emails.
        my $thread_user_id = $recipients{$to} ? $recipients{$to}->id : 0;
    
        my $vars = { 'flag'            => $flag,
                     'old_flag'        => $old_flag,
                     'to'              => $to,
                     'bug'             => $bug,
                     'attachment'      => $attachment,
                     'threadingmarker' => build_thread_marker($bug->id, $thread_user_id) };

        my $lang = $recipients{$to} ?
          $recipients{$to}->settings->{'lang'}->{'value'} : $default_lang;

        my $template = Bugzilla->template_inner($lang);
        my $message;
        $template->process("request/email.txt.tmpl", $vars, \$message)
          || ThrowTemplateError($template->error());

        Bugzilla->template_inner("");
        MessageToMTA($message);
    }
}

# This is an internal function used by $bug->flag_types
# and $attachment->flag_types to collect data about available
# flag types and existing flags set on them. You should never
# call this function directly.
sub _flag_types {
    my ($class, $vars) = @_;

    my $target_type = $vars->{target_type};
    my $flags;

    # Retrieve all existing flags for this bug/attachment.
    if ($target_type eq 'bug') {
        my $bug_id = delete $vars->{bug_id};
        $flags = $class->match({target_type => 'bug', bug_id => $bug_id});
    }
    elsif ($target_type eq 'attachment') {
        my $attach_id = delete $vars->{attach_id};
        $flags = $class->match({attach_id => $attach_id});
    }
    else {
        ThrowCodeError('bad_arg', {argument => 'target_type',
                                   function => $class . '->_flag_types'});
    }

    # Get all available flag types for the given product and component.
    my $flag_types = Bugzilla::FlagType::match($vars);

    $_->{flags} = [] foreach @$flag_types;
    my %flagtypes = map { $_->id => $_ } @$flag_types;

    # Group existing flags per type, and skip those becoming invalid
    # (which can happen when a bug is being moved into a new product
    # or component).
    @$flags = grep { exists $flagtypes{$_->type_id} } @$flags;
    push(@{$flagtypes{$_->type_id}->{flags}}, $_) foreach @$flags;

    return [sort {$a->sortkey <=> $b->sortkey || $a->name cmp $b->name} values %flagtypes];
}

=head1 SEE ALSO

=over

=item B<Bugzilla::FlagType>

=back


=head1 CONTRIBUTORS

=over

=item Myk Melez <myk@mozilla.org>

=item Jouni Heikniemi <jouni@heikniemi.net>

=item Kevin Benton <kevin.benton@amd.com>

=item Frédéric Buclin <LpSolit@gmail.com>

=back

=cut

1;
