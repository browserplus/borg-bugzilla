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
# Contributor(s): Dawn Endico    <endico@mozilla.org>
#                 Terry Weissman <terry@mozilla.org>
#                 Chris Yeh      <cyeh@bluemartini.com>
#                 Bradley Baetz  <bbaetz@acm.org>
#                 Dave Miller    <justdave@bugzilla.org>
#                 Max Kanat-Alexander <mkanat@bugzilla.org>
#                 Frédéric Buclin <LpSolit@gmail.com>
#                 Lance Larsh <lance.larsh@oracle.com>

package Bugzilla::Bug;

use strict;

use Bugzilla::Attachment;
use Bugzilla::Constants;
use Bugzilla::Field;
use Bugzilla::Flag;
use Bugzilla::FlagType;
use Bugzilla::Hook;
use Bugzilla::Keyword;
use Bugzilla::Milestone;
use Bugzilla::User;
use Bugzilla::Util;
use Bugzilla::Version;
use Bugzilla::Error;
use Bugzilla::Product;
use Bugzilla::Component;
use Bugzilla::Group;
use Bugzilla::Status;
use Bugzilla::Comment;

use List::Util qw(min);
use Storable qw(dclone);
use URI;
use URI::QueryParam;

use base qw(Bugzilla::Object Exporter);
@Bugzilla::Bug::EXPORT = qw(
    bug_alias_to_id
    RemoveVotes CheckIfVotedConfirmed
    LogActivityEntry
    editable_bug_fields
);

#####################################################################
# Constants
#####################################################################

use constant DB_TABLE   => 'bugs';
use constant ID_FIELD   => 'bug_id';
use constant NAME_FIELD => 'alias';
use constant LIST_ORDER => ID_FIELD;

# This is a sub because it needs to call other subroutines.
sub DB_COLUMNS {
    my $dbh = Bugzilla->dbh;
    my @custom = grep {$_->type != FIELD_TYPE_MULTI_SELECT}
                      Bugzilla->active_custom_fields;
    my @custom_names = map {$_->name} @custom;

    my @columns = (qw(
        alias
        assigned_to
        bug_file_loc
        bug_id
        bug_severity
        bug_status
        cclist_accessible
        component_id
        delta_ts
        estimated_time
        everconfirmed
        op_sys
        priority
        product_id
        qa_contact
        remaining_time
        rep_platform
        reporter_accessible
        resolution
        short_desc
        status_whiteboard
        target_milestone
        version
    ),
    'reporter    AS reporter_id',
    $dbh->sql_date_format('creation_ts', '%Y.%m.%d %H:%i') . ' AS creation_ts',
    $dbh->sql_date_format('deadline', '%Y-%m-%d') . ' AS deadline',
    @custom_names);
    
    Bugzilla::Hook::process("bug_columns", { columns => \@columns });
    
    return @columns;
}

use constant REQUIRED_CREATE_FIELDS => qw(
    component
    product
    short_desc
    version
);

# There are also other, more complex validators that are called
# from run_create_validators.
sub VALIDATORS {
    my $cache = Bugzilla->request_cache;
    return $cache->{bug_validators} if defined $cache->{bug_validators};

    my $validators = {
        alias          => \&_check_alias,
        bug_file_loc   => \&_check_bug_file_loc,
        bug_severity   => \&_check_select_field,
        comment        => \&_check_comment,
        commentprivacy => \&_check_commentprivacy,
        deadline       => \&_check_deadline,
        estimated_time => \&_check_estimated_time,
        op_sys         => \&_check_select_field,
        priority       => \&_check_priority,
        product        => \&_check_product,
        remaining_time => \&_check_remaining_time,
        rep_platform   => \&_check_select_field,
        short_desc     => \&_check_short_desc,
        status_whiteboard => \&_check_status_whiteboard,
    };

    # Set up validators for custom fields.    
    foreach my $field (Bugzilla->active_custom_fields) {
        my $validator;
        if ($field->type == FIELD_TYPE_SINGLE_SELECT) {
            $validator = \&_check_select_field;
        }
        elsif ($field->type == FIELD_TYPE_MULTI_SELECT) {
            $validator = \&_check_multi_select_field;
        }
        elsif ($field->type == FIELD_TYPE_DATETIME) {
            $validator = \&_check_datetime_field;
        }
        elsif ($field->type == FIELD_TYPE_FREETEXT) {
            $validator = \&_check_freetext_field;
        }
        elsif ($field->type == FIELD_TYPE_BUG_ID) {
            $validator = \&_check_bugid_field;
        }
        else {
            $validator = \&_check_default_field;
        }
        $validators->{$field->name} = $validator;
    }

    $cache->{bug_validators} = $validators;
    return $cache->{bug_validators};
};

use constant UPDATE_VALIDATORS => {
    assigned_to         => \&_check_assigned_to,
    bug_status          => \&_check_bug_status,
    cclist_accessible   => \&Bugzilla::Object::check_boolean,
    dup_id              => \&_check_dup_id,
    everconfirmed       => \&Bugzilla::Object::check_boolean,
    qa_contact          => \&_check_qa_contact,
    reporter_accessible => \&Bugzilla::Object::check_boolean,
    resolution          => \&_check_resolution,
    target_milestone    => \&_check_target_milestone,
    version             => \&_check_version,
};

sub UPDATE_COLUMNS {
    my @custom = grep {$_->type != FIELD_TYPE_MULTI_SELECT}
                      Bugzilla->active_custom_fields;
    my @custom_names = map {$_->name} @custom;
    my @columns = qw(
        alias
        assigned_to
        bug_file_loc
        bug_severity
        bug_status
        cclist_accessible
        component_id
        deadline
        estimated_time
        everconfirmed
        op_sys
        priority
        product_id
        qa_contact
        remaining_time
        rep_platform
        reporter_accessible
        resolution
        short_desc
        status_whiteboard
        target_milestone
        version
    );
    push(@columns, @custom_names);
    return @columns;
};

use constant NUMERIC_COLUMNS => qw(
    estimated_time
    remaining_time
);

sub DATE_COLUMNS {
    my @fields = Bugzilla->get_fields(
        { custom => 1, type => FIELD_TYPE_DATETIME });
    return map { $_->name } @fields;
}

# This is used by add_comment to know what we validate before putting in
# the DB.
use constant UPDATE_COMMENT_COLUMNS => qw(
    thetext
    work_time
    type
    extra_data
    isprivate
);

# Used in LogActivityEntry(). Gives the max length of lines in the
# activity table.
use constant MAX_LINE_LENGTH => 254;

# This maps the names of internal Bugzilla bug fields to things that would
# make sense to somebody who's not intimately familiar with the inner workings
# of Bugzilla. (These are the field names that the WebService and email_in.pl
# use.)
use constant FIELD_MAP => {
    creation_time    => 'creation_ts',
    description      => 'comment',
    id               => 'bug_id',
    last_change_time => 'delta_ts',
    platform         => 'rep_platform',
    severity         => 'bug_severity',
    status           => 'bug_status',
    summary          => 'short_desc',
    url              => 'bug_file_loc',
    whiteboard       => 'status_whiteboard',

    # These are special values for the WebService Bug.search method.
    limit            => 'LIMIT',
    offset           => 'OFFSET',
};

#####################################################################

sub new {
    my $invocant = shift;
    my $class = ref($invocant) || $invocant;
    my $param = shift;

    # Remove leading "#" mark if we've just been passed an id.
    if (!ref $param && $param =~ /^#(\d+)$/) {
        $param = $1;
    }

    # If we get something that looks like a word (not a number),
    # make it the "name" param.
    if (!defined $param || (!ref($param) && $param !~ /^\d+$/)) {
        # But only if aliases are enabled.
        if (Bugzilla->params->{'usebugaliases'} && $param) {
            $param = { name => $param };
        }
        else {
            # Aliases are off, and we got something that's not a number.
            my $error_self = {};
            bless $error_self, $class;
            $error_self->{'bug_id'} = $param;
            $error_self->{'error'}  = 'InvalidBugId';
            return $error_self;
        }
    }

    unshift @_, $param;
    my $self = $class->SUPER::new(@_);

    # Bugzilla::Bug->new always returns something, but sets $self->{error}
    # if the bug wasn't found in the database.
    if (!$self) {
        my $error_self = {};
        if (ref $param) {
            $error_self->{bug_id} = $param->{name};
            $error_self->{error}  = 'InvalidBugId';
        }
        else {
            $error_self->{bug_id} = $param;
            $error_self->{error}  = 'NotFound';
        }
        bless $error_self, $class;
        return $error_self;
    }

    return $self;
}

sub check {
    my $class = shift;
    my ($id, $field) = @_;

    ThrowUserError('improper_bug_id_field_value', { field => $field }) unless defined $id;

    # Bugzilla::Bug throws lots of special errors, so we don't call
    # SUPER::check, we just call our new and do our own checks.
    my $self = $class->new(trim($id));
    # For error messages, use the id that was returned by new(), because
    # it's cleaned up.
    $id = $self->id;

    if ($self->{error}) {
        if ($self->{error} eq 'NotFound') {
             ThrowUserError("bug_id_does_not_exist", { bug_id => $id });
        }
        if ($self->{error} eq 'InvalidBugId') {
            ThrowUserError("improper_bug_id_field_value",
                              { bug_id => $id,
                                field  => $field });
        }
    }

    unless ($field && $field =~ /^(dependson|blocked|dup_id)$/) {
        $self->check_is_visible;
    }
    return $self;
}

sub check_is_visible {
    my $self = shift;
    my $user = Bugzilla->user;

    if (!$user->can_see_bug($self->id)) {
        # The error the user sees depends on whether or not they are
        # logged in (i.e. $user->id contains the user's positive integer ID).
        if ($user->id) {
            ThrowUserError("bug_access_denied", { bug_id => $self->id });
        } else {
            ThrowUserError("bug_access_query", { bug_id => $self->id });
        }
    }
}

sub match {
    my $class = shift;
    my ($params) = @_;

    # Allow matching certain fields by name (in addition to matching by ID).
    my %translate_fields = (
        assigned_to => 'Bugzilla::User',
        qa_contact  => 'Bugzilla::User',
        reporter    => 'Bugzilla::User',
        product     => 'Bugzilla::Product',
        component   => 'Bugzilla::Component',
    );
    my %translated;

    foreach my $field (keys %translate_fields) {
        my @ids;
        # Convert names to ids. We use "exists" everywhere since people can
        # legally specify "undef" to mean IS NULL (even though most of these
        # fields can't be NULL, people can still specify it...).
        if (exists $params->{$field}) {
            my $names = $params->{$field};
            my $type = $translate_fields{$field};
            my $param = $type eq 'Bugzilla::User' ? 'login_name' : 'name';
            # We call Bugzilla::Object::match directly to avoid the
            # Bugzilla::User::match implementation which is different.
            my $objects = Bugzilla::Object::match($type, { $param => $names });
            push(@ids, map { $_->id } @$objects);
        }
        # You can also specify ids directly as arguments to this function,
        # so include them in the list if they have been specified.
        if (exists $params->{"${field}_id"}) {
            my $current_ids = $params->{"${field}_id"};
            my @id_array = ref $current_ids ? @$current_ids : ($current_ids);
            push(@ids, @id_array);
        }
        # We do this "or" instead of a "scalar(@ids)" to handle the case
        # when people passed only invalid object names. Otherwise we'd
        # end up with a SUPER::match call with zero criteria (which dies).
        if (exists $params->{$field} or exists $params->{"${field}_id"}) {
            $translated{$field} = scalar(@ids) == 1 ? $ids[0] : \@ids;
        }
    }

    # The user fields don't have an _id on the end of them in the database,
    # but the product & component fields do, so we have to have separate
    # code to deal with the different sets of fields here.
    foreach my $field (qw(assigned_to qa_contact reporter)) {
        delete $params->{"${field}_id"};
        $params->{$field} = $translated{$field} 
            if exists $translated{$field};
    }
    foreach my $field (qw(product component)) {
        delete $params->{$field};
        $params->{"${field}_id"} = $translated{$field} 
            if exists $translated{$field};
    }

    return $class->SUPER::match(@_);
}

# Docs for create() (there's no POD in this file yet, but we very
# much need this documented right now):
#
# The same as Bugzilla::Object->create. Parameters are only required
# if they say so below.
#
# Params:
#
# C<product>     - B<Required> The name of the product this bug is being
#                  filed against.
# C<component>   - B<Required> The name of the component this bug is being
#                  filed against.
#
# C<bug_severity> - B<Required> The severity for the bug, a string.
# C<creation_ts>  - B<Required> A SQL timestamp for when the bug was created.
# C<short_desc>   - B<Required> A summary for the bug.
# C<op_sys>       - B<Required> The OS the bug was found against.
# C<priority>     - B<Required> The initial priority for the bug.
# C<rep_platform> - B<Required> The platform the bug was found against.
# C<version>      - B<Required> The version of the product the bug was found in.
#
# C<alias>        - An alias for this bug. Will be ignored if C<usebugaliases>
#                   is off.
# C<target_milestone> - When this bug is expected to be fixed.
# C<status_whiteboard> - A string.
# C<bug_status>   - The initial status of the bug, a string.
# C<bug_file_loc> - The URL field.
#
# C<assigned_to> - The full login name of the user who the bug is
#                  initially assigned to.
# C<qa_contact>  - The full login name of the QA Contact for this bug. 
#                  Will be ignored if C<useqacontact> is off.
#
# C<estimated_time> - For time-tracking. Will be ignored if 
#                     C<timetrackinggroup> is not set, or if the current
#                     user is not a member of the timetrackinggroup.
# C<deadline>       - For time-tracking. Will be ignored for the same
#                     reasons as C<estimated_time>.
sub create {
    my ($class, $params) = @_;
    my $dbh = Bugzilla->dbh;

    $dbh->bz_start_transaction();

    # These fields have default values which we can use if they are undefined.
    $params->{bug_severity} = Bugzilla->params->{defaultseverity}
      unless defined $params->{bug_severity};
    $params->{priority} = Bugzilla->params->{defaultpriority}
      unless defined $params->{priority};
    $params->{op_sys} = Bugzilla->params->{defaultopsys}
      unless defined $params->{op_sys};
    $params->{rep_platform} = Bugzilla->params->{defaultplatform}
      unless defined $params->{rep_platform};
    # Make sure a comment is always defined.
    $params->{comment} = '' unless defined $params->{comment};

    $class->check_required_create_fields($params);
    $params = $class->run_create_validators($params);

    # These are not a fields in the bugs table, so we don't pass them to
    # insert_create_data.
    my $cc_ids     = delete $params->{cc};
    my $groups     = delete $params->{groups};
    my $depends_on = delete $params->{dependson};
    my $blocked    = delete $params->{blocked};
    my ($comment, $privacy) = ($params->{comment}, $params->{commentprivacy});
    delete $params->{comment};
    delete $params->{commentprivacy};

    # Set up the keyword cache for bug creation.
    my $keywords = $params->{keywords};
    $params->{keywords} = join(', ', sort {lc($a) cmp lc($b)} 
                                          map($_->name, @$keywords));

    # We don't want the bug to appear in the system until it's correctly
    # protected by groups.
    my $timestamp = delete $params->{creation_ts}; 

    my $ms_values = $class->_extract_multi_selects($params);
    my $bug = $class->insert_create_data($params);

    # Add the group restrictions
    my $sth_group = $dbh->prepare(
        'INSERT INTO bug_group_map (bug_id, group_id) VALUES (?, ?)');
    foreach my $group_id (@$groups) {
        $sth_group->execute($bug->bug_id, $group_id);
    }

    $dbh->do('UPDATE bugs SET creation_ts = ? WHERE bug_id = ?', undef,
             $timestamp, $bug->bug_id);
    # Update the bug instance as well
    $bug->{creation_ts} = $timestamp;

    # Add the CCs
    my $sth_cc = $dbh->prepare('INSERT INTO cc (bug_id, who) VALUES (?,?)');
    foreach my $user_id (@$cc_ids) {
        $sth_cc->execute($bug->bug_id, $user_id);
    }

    # Add in keywords
    my $sth_keyword = $dbh->prepare(
        'INSERT INTO keywords (bug_id, keywordid) VALUES (?, ?)');
    foreach my $keyword_id (map($_->id, @$keywords)) {
        $sth_keyword->execute($bug->bug_id, $keyword_id);
    }

    # Set up dependencies (blocked/dependson)
    my $sth_deps = $dbh->prepare(
        'INSERT INTO dependencies (blocked, dependson) VALUES (?, ?)');
    my $sth_bug_time = $dbh->prepare('UPDATE bugs SET delta_ts = ? WHERE bug_id = ?');

    foreach my $depends_on_id (@$depends_on) {
        $sth_deps->execute($bug->bug_id, $depends_on_id);
        # Log the reverse action on the other bug.
        LogActivityEntry($depends_on_id, 'blocked', '', $bug->bug_id,
                         $bug->{reporter_id}, $timestamp);
        $sth_bug_time->execute($timestamp, $depends_on_id);
    }
    foreach my $blocked_id (@$blocked) {
        $sth_deps->execute($blocked_id, $bug->bug_id);
        # Log the reverse action on the other bug.
        LogActivityEntry($blocked_id, 'dependson', '', $bug->bug_id,
                         $bug->{reporter_id}, $timestamp);
        $sth_bug_time->execute($timestamp, $blocked_id);
    }

    # Insert the values into the multiselect value tables
    foreach my $field (keys %$ms_values) {
        $dbh->do("DELETE FROM bug_$field where bug_id = ?",
                undef, $bug->bug_id);
        foreach my $value ( @{$ms_values->{$field}} ) {
            $dbh->do("INSERT INTO bug_$field (bug_id, value) VALUES (?,?)",
                    undef, $bug->bug_id, $value);
        }
    }

    # And insert the comment. We always insert a comment on bug creation,
    # but sometimes it's blank.
    my @columns = qw(bug_id who bug_when thetext);
    my @values  = ($bug->bug_id, $bug->{reporter_id}, $timestamp, $comment);
    # We don't include the "isprivate" column unless it was specified. 
    # This allows it to fall back to its database default.
    if (defined $privacy) {
        push(@columns, 'isprivate');
        push(@values, $privacy);
    }
    my $qmarks = "?," x @columns;
    chop($qmarks);
    $dbh->do('INSERT INTO longdescs (' . join(',', @columns)  . ")
                   VALUES ($qmarks)", undef, @values);

    Bugzilla::Hook::process('bug_end_of_create', { bug => $bug,
                                                   timestamp => $timestamp,
                                                 });

    $dbh->bz_commit_transaction();

    # Because MySQL doesn't support transactions on the fulltext table,
    # we do this after we've committed the transaction. That way we're
    # sure we're inserting a good Bug ID.
    $bug->_sync_fulltext('new bug');

    return $bug;
}

sub run_create_validators {
    my $class  = shift;
    my $params = $class->SUPER::run_create_validators(@_);

    my $product = $params->{product};
    $params->{product_id} = $product->id;
    delete $params->{product};

    ($params->{bug_status}, $params->{everconfirmed})
        = $class->_check_bug_status($params->{bug_status}, $product,
                                    $params->{comment});

    $params->{target_milestone} = $class->_check_target_milestone(
        $params->{target_milestone}, $product);

    $params->{version} = $class->_check_version($params->{version}, $product);

    $params->{keywords} = $class->_check_keywords($params->{keywords}, $product);

    $params->{groups} = $class->_check_groups($product,
        $params->{groups});

    my $component = $class->_check_component($params->{component}, $product);
    $params->{component_id} = $component->id;
    delete $params->{component};

    $params->{assigned_to} = 
        $class->_check_assigned_to($params->{assigned_to}, $component);
    $params->{qa_contact} =
        $class->_check_qa_contact($params->{qa_contact}, $component);
    $params->{cc} = $class->_check_cc($component, $params->{cc});

    # Callers cannot set reporter, creation_ts, or delta_ts.
    $params->{reporter} = $class->_check_reporter();
    $params->{creation_ts} = 
        Bugzilla->dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');
    $params->{delta_ts} = $params->{creation_ts};

    if ($params->{estimated_time}) {
        $params->{remaining_time} = $params->{estimated_time};
    }

    $class->_check_strict_isolation($params->{cc}, $params->{assigned_to},
                                    $params->{qa_contact}, $product);

    ($params->{dependson}, $params->{blocked}) = 
        $class->_check_dependencies($params->{dependson}, $params->{blocked},
                                    $product);

    # You can't set these fields on bug creation (or sometimes ever).
    delete $params->{resolution};
    delete $params->{votes};
    delete $params->{lastdiffed};
    delete $params->{bug_id};

    Bugzilla::Hook::process('bug_end_of_create_validators',
                            { params => $params });

    return $params;
}

sub update {
    my $self = shift;

    my $dbh = Bugzilla->dbh;
    # XXX This is just a temporary hack until all updating happens
    # inside this function.
    my $delta_ts = shift || $dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');

    my ($changes, $old_bug) = $self->SUPER::update(@_);

    # Certain items in $changes have to be fixed so that they hold
    # a name instead of an ID.
    foreach my $field (qw(product_id component_id)) {
        my $change = delete $changes->{$field};
        if ($change) {
            my $new_field = $field;
            $new_field =~ s/_id$//;
            $changes->{$new_field} = 
                [$self->{"_old_${new_field}_name"}, $self->$new_field];
        }
    }
    foreach my $field (qw(qa_contact assigned_to)) {
        if ($changes->{$field}) {
            my ($from, $to) = @{ $changes->{$field} };
            $from = $old_bug->$field->login if $from;
            $to   = $self->$field->login    if $to;
            $changes->{$field} = [$from, $to];
        }
    }

    # CC
    my @old_cc = map {$_->id} @{$old_bug->cc_users};
    my @new_cc = map {$_->id} @{$self->cc_users};
    my ($removed_cc, $added_cc) = diff_arrays(\@old_cc, \@new_cc);
    
    if (scalar @$removed_cc) {
        $dbh->do('DELETE FROM cc WHERE bug_id = ? AND ' 
                 . $dbh->sql_in('who', $removed_cc), undef, $self->id);
    }
    foreach my $user_id (@$added_cc) {
        $dbh->do('INSERT INTO cc (bug_id, who) VALUES (?,?)',
                 undef, $self->id, $user_id);
    }
    # If any changes were found, record it in the activity log
    if (scalar @$removed_cc || scalar @$added_cc) {
        my $removed_users = Bugzilla::User->new_from_list($removed_cc);
        my $added_users   = Bugzilla::User->new_from_list($added_cc);
        my $removed_names = join(', ', (map {$_->login} @$removed_users));
        my $added_names   = join(', ', (map {$_->login} @$added_users));
        $changes->{cc} = [$removed_names, $added_names];
    }
    
    # Keywords
    my @old_kw_ids = map { $_->id } @{$old_bug->keyword_objects};
    my @new_kw_ids = map { $_->id } @{$self->keyword_objects};

    my ($removed_kw, $added_kw) = diff_arrays(\@old_kw_ids, \@new_kw_ids);

    if (scalar @$removed_kw) {
        $dbh->do('DELETE FROM keywords WHERE bug_id = ? AND ' 
                 . $dbh->sql_in('keywordid', $removed_kw), undef, $self->id);
    }
    foreach my $keyword_id (@$added_kw) {
        $dbh->do('INSERT INTO keywords (bug_id, keywordid) VALUES (?,?)',
                 undef, $self->id, $keyword_id);
    }
    $dbh->do('UPDATE bugs SET keywords = ? WHERE bug_id = ?', undef,
             $self->keywords, $self->id);
    # If any changes were found, record it in the activity log
    if (scalar @$removed_kw || scalar @$added_kw) {
        my $removed_keywords = Bugzilla::Keyword->new_from_list($removed_kw);
        my $added_keywords   = Bugzilla::Keyword->new_from_list($added_kw);
        my $removed_names = join(', ', (map {$_->name} @$removed_keywords));
        my $added_names   = join(', ', (map {$_->name} @$added_keywords));
        $changes->{keywords} = [$removed_names, $added_names];
    }

    # Dependencies
    foreach my $pair ([qw(dependson blocked)], [qw(blocked dependson)]) {
        my ($type, $other) = @$pair;
        my $old = $old_bug->$type;
        my $new = $self->$type;
        
        my ($removed, $added) = diff_arrays($old, $new);
        foreach my $removed_id (@$removed) {
            $dbh->do("DELETE FROM dependencies WHERE $type = ? AND $other = ?",
                     undef, $removed_id, $self->id);
            
            # Add an activity entry for the other bug.
            LogActivityEntry($removed_id, $other, $self->id, '',
                             Bugzilla->user->id, $delta_ts);
            # Update delta_ts on the other bug so that we trigger mid-airs.
            $dbh->do('UPDATE bugs SET delta_ts = ? WHERE bug_id = ?',
                     undef, $delta_ts, $removed_id);
        }
        foreach my $added_id (@$added) {
            $dbh->do("INSERT INTO dependencies ($type, $other) VALUES (?,?)",
                     undef, $added_id, $self->id);
            
            # Add an activity entry for the other bug.
            LogActivityEntry($added_id, $other, '', $self->id,
                             Bugzilla->user->id, $delta_ts);
            # Update delta_ts on the other bug so that we trigger mid-airs.
            $dbh->do('UPDATE bugs SET delta_ts = ? WHERE bug_id = ?',
                     undef, $delta_ts, $added_id);
        }
        
        if (scalar(@$removed) || scalar(@$added)) {
            $changes->{$type} = [join(', ', @$removed), join(', ', @$added)];
        }
    }

    # Groups
    my %old_groups = map {$_->id => $_} @{$old_bug->groups_in};
    my %new_groups = map {$_->id => $_} @{$self->groups_in};
    my ($removed_gr, $added_gr) = diff_arrays([keys %old_groups],
                                              [keys %new_groups]);
    if (scalar @$removed_gr || scalar @$added_gr) {
        if (@$removed_gr) {
            my $qmarks = join(',', ('?') x @$removed_gr);
            $dbh->do("DELETE FROM bug_group_map
                       WHERE bug_id = ? AND group_id IN ($qmarks)", undef,
                     $self->id, @$removed_gr);
        }
        my $sth_insert = $dbh->prepare(
            'INSERT INTO bug_group_map (bug_id, group_id) VALUES (?,?)');
        foreach my $gid (@$added_gr) {
            $sth_insert->execute($self->id, $gid);
        }
        my @removed_names = map { $old_groups{$_}->name } @$removed_gr;
        my @added_names   = map { $new_groups{$_}->name } @$added_gr;
        $changes->{'bug_group'} = [join(', ', @removed_names),
                                   join(', ', @added_names)];
    }

    # Flags
    my ($removed, $added) = Bugzilla::Flag->update_flags($self, $old_bug, $delta_ts);
    if ($removed || $added) {
        $changes->{'flagtypes.name'} = [$removed, $added];
    }

    # Comments
    foreach my $comment (@{$self->{added_comments} || []}) {
        my $columns = join(',', keys %$comment);
        my @values  = values %$comment;
        my $qmarks  = join(',', ('?') x @values);
        $dbh->do("INSERT INTO longdescs (bug_id, who, bug_when, $columns)
                       VALUES (?,?,?,$qmarks)", undef,
                 $self->bug_id, Bugzilla->user->id, $delta_ts, @values);
        if ($comment->{work_time}) {
            LogActivityEntry($self->id, "work_time", "", $comment->{work_time},
                Bugzilla->user->id, $delta_ts);
        }
    }
    
    foreach my $comment_id (keys %{$self->{comment_isprivate} || {}}) {
        $dbh->do("UPDATE longdescs SET isprivate = ? WHERE comment_id = ?",
                 undef, $self->{comment_isprivate}->{$comment_id}, $comment_id);
        # XXX It'd be nice to track this in the bug activity.
    }

    # Insert the values into the multiselect value tables
    my @multi_selects = grep {$_->type == FIELD_TYPE_MULTI_SELECT}
                             Bugzilla->active_custom_fields;
    foreach my $field (@multi_selects) {
        my $name = $field->name;
        my ($removed, $added) = diff_arrays($old_bug->$name, $self->$name);
        if (scalar @$removed || scalar @$added) {
            $changes->{$name} = [join(', ', @$removed), join(', ', @$added)];

            $dbh->do("DELETE FROM bug_$name where bug_id = ?",
                     undef, $self->id);
            foreach my $value (@{$self->$name}) {
                $dbh->do("INSERT INTO bug_$name (bug_id, value) VALUES (?,?)",
                         undef, $self->id, $value);
            }
        }
    }

    # See Also
    my ($removed_see, $added_see) = 
        diff_arrays($old_bug->see_also, $self->see_also);

    if (scalar @$removed_see) {
        $dbh->do('DELETE FROM bug_see_also WHERE bug_id = ? AND '
                 . $dbh->sql_in('value', [('?') x @$removed_see]),
                  undef, $self->id, @$removed_see);
    }
    foreach my $url (@$added_see) {
        $dbh->do('INSERT INTO bug_see_also (bug_id, value) VALUES (?,?)',
                 undef, $self->id, $url);
    }
    # If any changes were found, record it in the activity log
    if (scalar @$removed_see || scalar @$added_see) {
        $changes->{see_also} = [join(', ', @$removed_see),
                                join(', ', @$added_see)];
    }

    # Log bugs_activity items
    # XXX Eventually, when bugs_activity is able to track the dupe_id,
    # this code should go below the duplicates-table-updating code below.
    foreach my $field (keys %$changes) {
        my $change = $changes->{$field};
        my $from = defined $change->[0] ? $change->[0] : '';
        my $to   = defined $change->[1] ? $change->[1] : '';
        LogActivityEntry($self->id, $field, $from, $to, Bugzilla->user->id,
                         $delta_ts);
    }

    # Check if we have to update the duplicates table and the other bug.
    my ($old_dup, $cur_dup) = ($old_bug->dup_id || 0, $self->dup_id || 0);
    if ($old_dup != $cur_dup) {
        $dbh->do("DELETE FROM duplicates WHERE dupe = ?", undef, $self->id);
        if ($cur_dup) {
            $dbh->do('INSERT INTO duplicates (dupe, dupe_of) VALUES (?,?)',
                     undef, $self->id, $cur_dup);
            if (my $update_dup = delete $self->{_dup_for_update}) {
                $update_dup->update();
            }
        }
        
        $changes->{'dup_id'} = [$old_dup || undef, $cur_dup || undef];
    }

    Bugzilla::Hook::process('bug_end_of_update', { bug       => $self,
                                                   timestamp => $delta_ts,
                                                   changes   => $changes,
                                                 });

    # If any change occurred, refresh the timestamp of the bug.
    if (scalar(keys %$changes) || $self->{added_comments}) {
        $dbh->do('UPDATE bugs SET delta_ts = ? WHERE bug_id = ?',
                 undef, ($delta_ts, $self->id));
        $self->{delta_ts} = $delta_ts;
    }

    # The only problem with this here is that update() is often called
    # in the middle of a transaction, and if that transaction is rolled
    # back, this change will *not* be rolled back. As we expect rollbacks
    # to be extremely rare, that is OK for us.
    $self->_sync_fulltext()
        if $self->{added_comments} || $changes->{short_desc};

    # Remove obsolete internal variables.
    delete $self->{'_old_assigned_to'};
    delete $self->{'_old_qa_contact'};

    # Also flush the visible_bugs cache for this bug as the user's
    # relationship with this bug may have changed.
    delete Bugzilla->user->{_visible_bugs_cache}->{$self->id};

    return $changes;
}

# Used by create().
# We need to handle multi-select fields differently than normal fields,
# because they're arrays and don't go into the bugs table.
sub _extract_multi_selects {
    my ($invocant, $params) = @_;

    my @multi_selects = grep {$_->type == FIELD_TYPE_MULTI_SELECT}
                             Bugzilla->active_custom_fields;
    my %ms_values;
    foreach my $field (@multi_selects) {
        my $name = $field->name;
        if (exists $params->{$name}) {
            my $array = delete($params->{$name}) || [];
            $ms_values{$name} = $array;
        }
    }
    return \%ms_values;
}

# Should be called any time you update short_desc or change a comment.
sub _sync_fulltext {
    my ($self, $new_bug) = @_;
    my $dbh = Bugzilla->dbh;
    if ($new_bug) {
        $dbh->do('INSERT INTO bugs_fulltext (bug_id, short_desc)
                  SELECT bug_id, short_desc FROM bugs WHERE bug_id = ?',
                 undef, $self->id);
    }
    else {
        $dbh->do('UPDATE bugs_fulltext SET short_desc = ? WHERE bug_id = ?',
                 undef, $self->short_desc, $self->id);
    }
    my $comments = $dbh->selectall_arrayref(
        'SELECT thetext, isprivate FROM longdescs WHERE bug_id = ?',
        undef, $self->id);
    my $all = join("\n", map { $_->[0] } @$comments);
    my @no_private = grep { !$_->[1] } @$comments;
    my $nopriv_string = join("\n", map { $_->[0] } @no_private);
    $dbh->do('UPDATE bugs_fulltext SET comments = ?, comments_noprivate = ?
               WHERE bug_id = ?', undef, $all, $nopriv_string, $self->id);
}


# This is the correct way to delete bugs from the DB.
# No bug should be deleted from anywhere else except from here.
#
sub remove_from_db {
    my ($self) = @_;
    my $dbh = Bugzilla->dbh;

    if ($self->{'error'}) {
        ThrowCodeError("bug_error", { bug => $self });
    }

    my $bug_id = $self->{'bug_id'};

    # tables having 'bugs.bug_id' as a foreign key:
    # - attachments
    # - bug_group_map
    # - bugs
    # - bugs_activity
    # - bugs_fulltext
    # - cc
    # - dependencies
    # - duplicates
    # - flags
    # - keywords
    # - longdescs
    # - votes

    # Also, the attach_data table uses attachments.attach_id as a foreign
    # key, and so indirectly depends on a bug deletion too.

    $dbh->bz_start_transaction();

    $dbh->do("DELETE FROM bug_group_map WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM bugs_activity WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM cc WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM dependencies WHERE blocked = ? OR dependson = ?",
             undef, ($bug_id, $bug_id));
    $dbh->do("DELETE FROM duplicates WHERE dupe = ? OR dupe_of = ?",
             undef, ($bug_id, $bug_id));
    $dbh->do("DELETE FROM flags WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM keywords WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM votes WHERE bug_id = ?", undef, $bug_id);

    # The attach_data table doesn't depend on bugs.bug_id directly.
    my $attach_ids =
        $dbh->selectcol_arrayref("SELECT attach_id FROM attachments
                                  WHERE bug_id = ?", undef, $bug_id);

    if (scalar(@$attach_ids)) {
        $dbh->do("DELETE FROM attach_data WHERE " 
                 . $dbh->sql_in('id', $attach_ids));
    }

    # Several of the previous tables also depend on attach_id.
    $dbh->do("DELETE FROM attachments WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM bugs WHERE bug_id = ?", undef, $bug_id);
    $dbh->do("DELETE FROM longdescs WHERE bug_id = ?", undef, $bug_id);

    $dbh->bz_commit_transaction();

    # The bugs_fulltext table doesn't support transactions.
    $dbh->do("DELETE FROM bugs_fulltext WHERE bug_id = ?", undef, $bug_id);

    # Now this bug no longer exists
    $self->DESTROY;
    return $self;
}

#####################################################################
# Validators
#####################################################################

sub _check_alias {
   my ($invocant, $alias) = @_;
   $alias = trim($alias);
   return undef if (!Bugzilla->params->{'usebugaliases'} || !$alias);

    # Make sure the alias isn't too long.
    if (length($alias) > 20) {
        ThrowUserError("alias_too_long");
    }
    # Make sure the alias isn't just a number.
    if ($alias =~ /^\d+$/) {
        ThrowUserError("alias_is_numeric", { alias => $alias });
    }
    # Make sure the alias has no commas or spaces.
    if ($alias =~ /[, ]/) {
        ThrowUserError("alias_has_comma_or_space", { alias => $alias });
    }
    # Make sure the alias is unique, or that it's already our alias.
    my $other_bug = new Bugzilla::Bug($alias);
    if (!$other_bug->{error}
        && (!ref $invocant || $other_bug->id != $invocant->id))
    {
        ThrowUserError("alias_in_use", { alias => $alias,
                                         bug_id => $other_bug->id });
    }

   return $alias;
}

sub _check_assigned_to {
    my ($invocant, $assignee, $component) = @_;
    my $user = Bugzilla->user;

    # Default assignee is the component owner.
    my $id;
    # If this is a new bug, you can only set the assignee if you have editbugs.
    # If you didn't specify the assignee, we use the default assignee.
    if (!ref $invocant
        && (!$user->in_group('editbugs', $component->product_id) || !$assignee))
    {
        $id = $component->default_assignee->id;
    } else {
        if (!ref $assignee) {
            $assignee = trim($assignee);
            # When updating a bug, assigned_to can't be empty.
            ThrowUserError("reassign_to_empty") if ref $invocant && !$assignee;
            $assignee = Bugzilla::User->check($assignee);
        }
        $id = $assignee->id;
        # create() checks this another way, so we don't have to run this
        # check during create().
        $invocant->_check_strict_isolation_for_user($assignee) if ref $invocant;
    }
    return $id;
}

sub _check_bug_file_loc {
    my ($invocant, $url) = @_;
    $url = '' if !defined($url);
    # On bug entry, if bug_file_loc is "http://", the default, use an 
    # empty value instead. However, on bug editing people can set that
    # back if they *really* want to.
    if (!ref $invocant && $url eq 'http://') {
        $url = '';
    }
    return $url;
}

sub _check_bug_status {
    my ($invocant, $new_status, $product, $comment) = @_;
    my $user = Bugzilla->user;
    my @valid_statuses;
    my $old_status; # Note that this is undef for new bugs.

    if (ref $invocant) {
        @valid_statuses = @{$invocant->statuses_available};
        $product = $invocant->product_obj;
        $old_status = $invocant->status;
        my $comments = $invocant->{added_comments} || [];
        $comment = $comments->[-1];
    }
    else {
        @valid_statuses = @{Bugzilla::Status->can_change_to()};
        if (!$product->allows_unconfirmed) {
            @valid_statuses = grep {$_->name ne 'UNCONFIRMED'} @valid_statuses;
        }
    }

    # Check permissions for users filing new bugs.
    if (!ref $invocant) {
        if ($user->in_group('editbugs', $product->id)
            || $user->in_group('canconfirm', $product->id)) {
            # If the user with privs hasn't selected another status,
            # select the first one of the list.
            unless ($new_status) {
                if (scalar(@valid_statuses) == 1) {
                    $new_status = $valid_statuses[0];
                }
                else {
                    $new_status = ($valid_statuses[0]->name ne 'UNCONFIRMED') ?
                                  $valid_statuses[0] : $valid_statuses[1];
                }
            }
        }
        else {
            # A user with no privs cannot choose the initial status.
            # If UNCONFIRMED is valid for this product, use it; else
            # use the first bug status available.
            if (grep {$_->name eq 'UNCONFIRMED'} @valid_statuses) {
                $new_status = 'UNCONFIRMED';
            }
            else {
                $new_status = $valid_statuses[0];
            }
        }
    }

    # Time to validate the bug status.
    $new_status = Bugzilla::Status->check($new_status) unless ref($new_status);
    # We skip this check if we are changing from a status to itself.
    if ( (!$old_status || $old_status->id != $new_status->id)
          && !grep {$_->name eq $new_status->name} @valid_statuses) 
    {
        ThrowUserError('illegal_bug_status_transition',
                       { old => $old_status, new => $new_status });
    }

    # Check if a comment is required for this change.
    if ($new_status->comment_required_on_change_from($old_status) && !$comment)
    {
        ThrowUserError('comment_required', { old => $old_status,
                                             new => $new_status });
        
    }
    
    if (ref $invocant && $new_status->name eq 'ASSIGNED'
        && Bugzilla->params->{"usetargetmilestone"}
        && Bugzilla->params->{"musthavemilestoneonaccept"}
        # musthavemilestoneonaccept applies only if at least two
        # target milestones are defined for the product.
        && scalar(@{ $product->milestones }) > 1
        && $invocant->target_milestone eq $product->default_milestone)
    {
        ThrowUserError("milestone_required", { bug => $invocant });
    }

    return $new_status->name if ref $invocant;
    return ($new_status->name, $new_status->name eq 'UNCONFIRMED' ? 0 : 1);
}

sub _check_cc {
    my ($invocant, $component, $ccs) = @_;
    return [map {$_->id} @{$component->initial_cc}] unless $ccs;

    # Allow comma-separated input as well as arrayrefs.
    $ccs = [split(/[\s,]+/, $ccs)] if !ref $ccs;

    my %cc_ids;
    foreach my $person (@$ccs) {
        next unless $person;
        my $id = login_to_id($person, THROW_ERROR);
        $cc_ids{$id} = 1;
    }

    # Enforce Default CC
    $cc_ids{$_->id} = 1 foreach (@{$component->initial_cc});

    return [keys %cc_ids];
}

sub _check_comment {
    my ($invocant, $comment) = @_;

    $comment = '' unless defined $comment;

    # Remove any trailing whitespace. Leading whitespace could be
    # a valid part of the comment.
    $comment =~ s/\s*$//s;
    $comment =~ s/\r\n?/\n/g; # Get rid of \r.

    ThrowUserError('comment_too_long') if length($comment) > MAX_COMMENT_LENGTH;
    return $comment;
}

sub _check_commentprivacy {
    my ($invocant, $comment_privacy) = @_;
    if ($comment_privacy && !Bugzilla->user->is_insider) {
        ThrowUserError('user_not_insider');
    }
    return $comment_privacy ? 1 : 0;
}

sub _check_comment_type {
    my ($invocant, $type) = @_;
    detaint_natural($type)
      || ThrowCodeError('bad_arg', { argument => 'type', 
                                     function => caller });
    return $type;
}

sub _check_component {
    my ($invocant, $name, $product) = @_;
    $name = trim($name);
    $name || ThrowUserError("require_component");
    ($product = $invocant->product_obj) if ref $invocant;
    my $obj = Bugzilla::Component->check({ product => $product, name => $name });
    return $obj;
}

sub _check_deadline {
    my ($invocant, $date) = @_;
    
    # Check time-tracking permissions.
    # deadline() returns '' instead of undef if no deadline is set.
    my $current = ref $invocant ? ($invocant->deadline || undef) : undef;
    return $current unless Bugzilla->user->is_timetracker;
    
    # Validate entered deadline
    $date = trim($date);
    return undef if !$date;
    validate_date($date)
        || ThrowUserError('illegal_date', { date   => $date,
                                            format => 'YYYY-MM-DD' });
    return $date;
}

# Takes two comma/space-separated strings and returns arrayrefs
# of valid bug IDs.
sub _check_dependencies {
    my ($invocant, $depends_on, $blocks, $product) = @_;

    if (!ref $invocant) {
        # Only editbugs users can set dependencies on bug entry.
        return ([], []) unless Bugzilla->user->in_group('editbugs',
                                                        $product->id);
    }

    my %deps_in = (dependson => $depends_on || '', blocked => $blocks || '');

    foreach my $type qw(dependson blocked) {
        my @bug_ids = ref($deps_in{$type}) 
            ? @{$deps_in{$type}} 
            : split(/[\s,]+/, $deps_in{$type});
        # Eliminate nulls.
        @bug_ids = grep {$_} @bug_ids;
        # We do this up here to make sure all aliases are converted to IDs.
        @bug_ids = map { $invocant->check($_, $type)->id } @bug_ids;
       
        my @check_access = @bug_ids;
        # When we're updating a bug, only added or removed bug_ids are 
        # checked for whether or not we can see/edit those bugs.
        if (ref $invocant) {
            my $old = $invocant->$type;
            my ($removed, $added) = diff_arrays($old, \@bug_ids);
            @check_access = (@$added, @$removed);
            
            # Check field permissions if we've changed anything.
            if (@check_access) {
                my $privs;
                if (!$invocant->check_can_change_field($type, 0, 1, \$privs)) {
                    ThrowUserError('illegal_change', { field => $type,
                                                       privs => $privs });
                }
            }
        }

        my $user = Bugzilla->user;
        foreach my $modified_id (@check_access) {
            my $delta_bug = $invocant->check($modified_id);
            # Under strict isolation, you can't modify a bug if you can't
            # edit it, even if you can see it.
            if (Bugzilla->params->{"strict_isolation"}) {
                if (!$user->can_edit_product($delta_bug->{'product_id'})) {
                    ThrowUserError("illegal_change_deps", {field => $type});
                }
            }
        }
        
        $deps_in{$type} = \@bug_ids;
    }

    # And finally, check for dependency loops.
    my $bug_id = ref($invocant) ? $invocant->id : 0;
    my %deps = ValidateDependencies($deps_in{dependson}, $deps_in{blocked}, $bug_id);

    return ($deps{'dependson'}, $deps{'blocked'});
}

sub _check_dup_id {
    my ($self, $dupe_of) = @_;
    my $dbh = Bugzilla->dbh;
    
    $dupe_of = trim($dupe_of);
    $dupe_of || ThrowCodeError('undefined_field', { field => 'dup_id' });
    # Validate the bug ID. The second argument will force check() to only
    # make sure that the bug exists, and convert the alias to the bug ID
    # if a string is passed. Group restrictions are checked below.
    my $dupe_of_bug = $self->check($dupe_of, 'dup_id');
    $dupe_of = $dupe_of_bug->id;

    # If the dupe is unchanged, we have nothing more to check.
    return $dupe_of if ($self->dup_id && $self->dup_id == $dupe_of);

    # If we come here, then the duplicate is new. We have to make sure
    # that we can view/change it (issue A on bug 96085).
    $dupe_of_bug->check_is_visible;

    # Make sure a loop isn't created when marking this bug
    # as duplicate.
    my %dupes;
    my $this_dup = $dupe_of;
    my $sth = $dbh->prepare('SELECT dupe_of FROM duplicates WHERE dupe = ?');

    while ($this_dup) {
        if ($this_dup == $self->id) {
            ThrowUserError('dupe_loop_detected', { bug_id  => $self->id,
                                                   dupe_of => $dupe_of });
        }
        # If $dupes{$this_dup} is already set to 1, then a loop
        # already exists which does not involve this bug.
        # As the user is not responsible for this loop, do not
        # prevent him from marking this bug as a duplicate.
        last if exists $dupes{$this_dup};
        $dupes{$this_dup} = 1;
        $this_dup = $dbh->selectrow_array($sth, undef, $this_dup);
    }

    my $cur_dup = $self->dup_id || 0;
    if ($cur_dup != $dupe_of && Bugzilla->params->{'commentonduplicate'}
        && !$self->{added_comments})
    {
        ThrowUserError('comment_required');
    }

    # Should we add the reporter to the CC list of the new bug?
    # If he can see the bug...
    if ($self->reporter->can_see_bug($dupe_of)) {
        # We only add him if he's not the reporter of the other bug.
        $self->{_add_dup_cc} = 1
            if $dupe_of_bug->reporter->id != $self->reporter->id;
    }
    # What if the reporter currently can't see the new bug? In the browser 
    # interface, we prompt the user. In other interfaces, we default to 
    # not adding the user, as the safest option.
    elsif (Bugzilla->usage_mode == USAGE_MODE_BROWSER) {
        # If we've already confirmed whether the user should be added...
        my $cgi = Bugzilla->cgi;
        my $add_confirmed = $cgi->param('confirm_add_duplicate');
        if (defined $add_confirmed) {
            $self->{_add_dup_cc} = $add_confirmed;
        }
        else {
            # Note that here we don't check if he user is already the reporter
            # of the dupe_of bug, since we already checked if he can *see*
            # the bug, above. People might have reporter_accessible turned
            # off, but cclist_accessible turned on, so they might want to
            # add the reporter even though he's already the reporter of the
            # dup_of bug.
            my $vars = {};
            my $template = Bugzilla->template;
            # Ask the user what they want to do about the reporter.
            $vars->{'cclist_accessible'} = $dupe_of_bug->cclist_accessible;
            $vars->{'original_bug_id'} = $dupe_of;
            $vars->{'duplicate_bug_id'} = $self->id;
            print $cgi->header();
            $template->process("bug/process/confirm-duplicate.html.tmpl", $vars)
              || ThrowTemplateError($template->error());
            exit;
        }
    }

    return $dupe_of;
}

sub _check_estimated_time {
    return $_[0]->_check_time($_[1], 'estimated_time');
}

sub _check_groups {
    my ($invocant, $product, $group_ids) = @_;

    my $user = Bugzilla->user;

    my %add_groups;
    my $controls = $product->group_controls;

    foreach my $id (@$group_ids) {
        my $group = new Bugzilla::Group($id)
            || ThrowUserError("invalid_group_ID");

        # This can only happen if somebody hacked the enter_bug form.
        ThrowCodeError("inactive_group", { name => $group->name })
            unless $group->is_active;

        my $membercontrol = $controls->{$id}
                            && $controls->{$id}->{membercontrol};
        my $othercontrol  = $controls->{$id} 
                            && $controls->{$id}->{othercontrol};
        
        my $permit = ($membercontrol && $user->in_group($group->name))
                     || $othercontrol;

        $add_groups{$id} = 1 if $permit;
    }

    foreach my $id (keys %$controls) {
        next unless $controls->{$id}->{'group'}->is_active;
        my $membercontrol = $controls->{$id}->{membercontrol} || 0;
        my $othercontrol  = $controls->{$id}->{othercontrol}  || 0;

        # Add groups required
        if ($membercontrol == CONTROLMAPMANDATORY
            || ($othercontrol == CONTROLMAPMANDATORY
                && !$user->in_group_id($id))) 
        {
            # User had no option, bug needs to be in this group.
            $add_groups{$id} = 1;
        }
    }

    my @add_groups = keys %add_groups;
    return \@add_groups;
}

sub _check_keywords {
    my ($invocant, $keyword_string, $product) = @_;
    $keyword_string = trim($keyword_string);
    return [] if !$keyword_string;
    
    # On creation, only editbugs users can set keywords.
    if (!ref $invocant) {
        return [] if !Bugzilla->user->in_group('editbugs', $product->id);
    }
    
    my %keywords;
    foreach my $keyword (split(/[\s,]+/, $keyword_string)) {
        next unless $keyword;
        my $obj = new Bugzilla::Keyword({ name => $keyword });
        ThrowUserError("unknown_keyword", { keyword => $keyword }) if !$obj;
        $keywords{$obj->id} = $obj;
    }
    return [values %keywords];
}

sub _check_product {
    my ($invocant, $name) = @_;
    $name = trim($name);
    # If we're updating the bug and they haven't changed the product,
    # always allow it.
    if (ref $invocant && lc($invocant->product_obj->name) eq lc($name)) {
        return $invocant->product_obj;
    }
    # Check that the product exists and that the user
    # is allowed to enter bugs into this product.
    Bugzilla->user->can_enter_product($name, THROW_ERROR);
    # can_enter_product already does everything that check_product
    # would do for us, so we don't need to use it.
    return new Bugzilla::Product({ name => $name });
}

sub _check_priority {
    my ($invocant, $priority) = @_;
    if (!ref $invocant && !Bugzilla->params->{'letsubmitterchoosepriority'}) {
        $priority = Bugzilla->params->{'defaultpriority'};
    }
    return $invocant->_check_select_field($priority, 'priority');
}

sub _check_qa_contact {
    my ($invocant, $qa_contact, $component) = @_;
    $qa_contact = trim($qa_contact) if !ref $qa_contact;
    
    my $id;
    if (!ref $invocant) {
        # Bugs get no QA Contact on creation if useqacontact is off.
        return undef if !Bugzilla->params->{useqacontact};
        # Set the default QA Contact if one isn't specified or if the
        # user doesn't have editbugs.
        if (!Bugzilla->user->in_group('editbugs', $component->product_id)
            || !$qa_contact)
        {
            $id = $component->default_qa_contact->id;
        }
    }
    
    # If a QA Contact was specified or if we're updating, check
    # the QA Contact for validity.
    if (!defined $id && $qa_contact) {
        $qa_contact = Bugzilla::User->check($qa_contact) if !ref $qa_contact;
        $id = $qa_contact->id;
        # create() checks this another way, so we don't have to run this
        # check during create().
        # If there is no QA contact, this check is not required.
        $invocant->_check_strict_isolation_for_user($qa_contact)
            if (ref $invocant && $id);
    }

    # "0" always means "undef", for QA Contact.
    return $id || undef;
}

sub _check_remaining_time {
    return $_[0]->_check_time($_[1], 'remaining_time');
}

sub _check_reporter {
    my $invocant = shift;
    my $reporter;
    if (ref $invocant) {
        # You cannot change the reporter of a bug.
        $reporter = $invocant->reporter->id;
    }
    else {
        # On bug creation, the reporter is the logged in user
        # (meaning that he must be logged in first!).
        $reporter = Bugzilla->user->id;
        $reporter || ThrowCodeError('invalid_user');
    }
    return $reporter;
}

sub _check_resolution {
    my ($self, $resolution) = @_;
    $resolution = trim($resolution);
    
    # Throw a special error for resolving bugs without a resolution
    # (or trying to change the resolution to '' on a closed bug without
    # using clear_resolution).
    ThrowUserError('missing_resolution', { status => $self->status->name })
        if !$resolution && !$self->status->is_open;
    
    # Make sure this is a valid resolution.
    $resolution = $self->_check_select_field($resolution, 'resolution');

    # Don't allow open bugs to have resolutions.
    ThrowUserError('resolution_not_allowed') if $self->status->is_open;
    
    # Check noresolveonopenblockers.
    if (Bugzilla->params->{"noresolveonopenblockers"} && $resolution eq 'FIXED')
    {
        my @dependencies = CountOpenDependencies($self->id);
        if (@dependencies) {
            ThrowUserError("still_unresolved_bugs",
                           { dependencies     => \@dependencies,
                             dependency_count => scalar @dependencies });
        }
    }

    # Check if they're changing the resolution and need to comment.
    if (Bugzilla->params->{'commentonchange_resolution'} 
        && $self->resolution && $resolution ne $self->resolution 
        && !$self->{added_comments})
    {
        ThrowUserError('comment_required');
    }
    
    return $resolution;
}

sub _check_short_desc {
    my ($invocant, $short_desc) = @_;
    # Set the parameter to itself, but cleaned up
    $short_desc = clean_text($short_desc) if $short_desc;

    if (!defined $short_desc || $short_desc eq '') {
        ThrowUserError("require_summary");
    }
    return $short_desc;
}

sub _check_status_whiteboard { return defined $_[1] ? $_[1] : ''; }

# Unlike other checkers, this one doesn't return anything.
sub _check_strict_isolation {
    my ($invocant, $ccs, $assignee, $qa_contact, $product) = @_;
    return unless Bugzilla->params->{'strict_isolation'};

    if (ref $invocant) {
        my $original = $invocant->new($invocant->id);

        # We only check people if they've been added. This way, if
        # strict_isolation is turned on when there are invalid users
        # on bugs, people can still add comments and so on.
        my @old_cc = map { $_->id } @{$original->cc_users};
        my @new_cc = map { $_->id } @{$invocant->cc_users};
        my ($removed, $added) = diff_arrays(\@old_cc, \@new_cc);
        $ccs = Bugzilla::User->new_from_list($added);

        $assignee = $invocant->assigned_to
            if $invocant->assigned_to->id != $original->assigned_to->id;
        if ($invocant->qa_contact
            && (!$original->qa_contact
                || $invocant->qa_contact->id != $original->qa_contact->id))
        {
            $qa_contact = $invocant->qa_contact;
        }
        $product = $invocant->product_obj;
    }

    my @related_users = @$ccs;
    push(@related_users, $assignee) if $assignee;

    if (Bugzilla->params->{'useqacontact'} && $qa_contact) {
        push(@related_users, $qa_contact);
    }

    @related_users = @{Bugzilla::User->new_from_list(\@related_users)}
        if !ref $invocant;

    # For each unique user in @related_users...(assignee and qa_contact
    # could be duplicates of users in the CC list)
    my %unique_users = map {$_->id => $_} @related_users;
    my @blocked_users;
    foreach my $id (keys %unique_users) {
        my $related_user = $unique_users{$id};
        if (!$related_user->can_edit_product($product->id) ||
            !$related_user->can_see_product($product->name)) {
            push (@blocked_users, $related_user->login);
        }
    }
    if (scalar(@blocked_users)) {
        my %vars = ( users   => \@blocked_users,
                     product => $product->name );
        if (ref $invocant) {
            $vars{'bug_id'} = $invocant->id;
        }
        else {
            $vars{'new'} = 1;
        }
        ThrowUserError("invalid_user_group", \%vars);
    }
}

# This is used by various set_ checkers, to make their code simpler.
sub _check_strict_isolation_for_user {
    my ($self, $user) = @_;
    return unless Bugzilla->params->{"strict_isolation"};
    if (!$user->can_edit_product($self->{product_id})) {
        ThrowUserError('invalid_user_group',
                       { users   => $user->login,
                         product => $self->product,
                         bug_id  => $self->id });
    }
}

sub _check_target_milestone {
    my ($invocant, $target, $product) = @_;
    $product = $invocant->product_obj if ref $invocant;

    $target = trim($target);
    $target = $product->default_milestone if !defined $target;
    my $object = Bugzilla::Milestone->check(
        { product => $product, name => $target });
    return $object->name;
}

sub _check_time {
    my ($invocant, $time, $field) = @_;

    my $current = 0;
    if (ref $invocant && $field ne 'work_time') {
        $current = $invocant->$field;
    }
    return $current unless Bugzilla->user->is_timetracker;
    
    $time = trim($time) || 0;
    ValidateTime($time, $field);
    return $time;
}

sub _check_version {
    my ($invocant, $version, $product) = @_;
    $version = trim($version);
    ($product = $invocant->product_obj) if ref $invocant;
    my $object = 
        Bugzilla::Version->check({ product => $product, name => $version });
    return $object->name;
}

sub _check_work_time {
    return $_[0]->_check_time($_[1], 'work_time');
}

# Custom Field Validators

sub _check_datetime_field {
    my ($invocant, $date_time) = @_;

    # Empty datetimes are empty strings or strings only containing
    # 0's, whitespace, and punctuation.
    if ($date_time =~ /^[\s0[:punct:]]*$/) {
        return undef;
    }

    $date_time = trim($date_time);
    my ($date, $time) = split(' ', $date_time);
    if ($date && !validate_date($date)) {
        ThrowUserError('illegal_date', { date   => $date,
                                         format => 'YYYY-MM-DD' });
    }
    if ($time && !validate_time($time)) {
        ThrowUserError('illegal_time', { 'time' => $time,
                                         format => 'HH:MM:SS' });
    }
    return $date_time
}

sub _check_default_field { return defined $_[1] ? trim($_[1]) : ''; }

sub _check_freetext_field {
    my ($invocant, $text) = @_;

    $text = (defined $text) ? trim($text) : '';
    if (length($text) > MAX_FREETEXT_LENGTH) {
        ThrowUserError('freetext_too_long', { text => $text });
    }
    return $text;
}

sub _check_multi_select_field {
    my ($invocant, $values, $field) = @_;

    # Allow users (mostly email_in.pl) to specify multi-selects as
    # comma-separated values.
    if (defined $values and !ref $values) {
        # We don't split on spaces because multi-select values can and often
        # do have spaces in them. (Theoretically they can have commas in them
        # too, but that's much less common and people should be able to work
        # around it pretty cleanly, if they want to use email_in.pl.)
        $values = [split(',', $values)];
    }

    return [] if !$values;
    my @checked_values;
    foreach my $value (@$values) {
        push(@checked_values, $invocant->_check_select_field($value, $field));
    }
    return \@checked_values;
}

sub _check_select_field {
    my ($invocant, $value, $field) = @_;
    my $object = Bugzilla::Field::Choice->type($field)->check($value);
    return $object->name;
}

sub _check_bugid_field {
    my ($invocant, $value, $field) = @_;
    return undef if !$value;
    return $invocant->check($value, $field)->id;
}

#####################################################################
# Class Accessors
#####################################################################

sub fields {
    my $class = shift;

   my @fields =
   (
        # Standard Fields
        # Keep this ordering in sync with bugzilla.dtd.
        qw(bug_id alias creation_ts short_desc delta_ts
           reporter_accessible cclist_accessible
           classification_id classification
           product component version rep_platform op_sys
           bug_status resolution dup_id see_also
           bug_file_loc status_whiteboard keywords
           priority bug_severity target_milestone
           dependson blocked votes everconfirmed
           reporter assigned_to cc estimated_time
           remaining_time actual_time deadline),

        # Conditional Fields
        Bugzilla->params->{'useqacontact'} ? "qa_contact" : (),
        # Custom Fields
        map { $_->name } Bugzilla->active_custom_fields
    );
    Bugzilla::Hook::process('bug_fields', {'fields' => \@fields} );
    
    return @fields;
}

#####################################################################
# Mutators 
#####################################################################

# To run check_can_change_field.
sub _set_global_validator {
    my ($self, $value, $field) = @_;
    my $current = $self->$field;
    my $privs;

    if (ref $current && ref($current) ne 'ARRAY'
        && $current->isa('Bugzilla::Object')) {
        $current = $current->id ;
    }
    if (ref $value && ref($value) ne 'ARRAY'
        && $value->isa('Bugzilla::Object')) {
        $value = $value->id ;
    }
    my $can = $self->check_can_change_field($field, $current, $value, \$privs);
    if (!$can) {
        if ($field eq 'assigned_to' || $field eq 'qa_contact') {
            $value   = user_id_to_login($value);
            $current = user_id_to_login($current);
        }
        ThrowUserError('illegal_change', { field    => $field,
                                           oldvalue => $current,
                                           newvalue => $value,
                                           privs    => $privs });
    }
}


#################
# "Set" Methods #
#################

sub set_alias { $_[0]->set('alias', $_[1]); }
sub set_assigned_to {
    my ($self, $value) = @_;
    $self->set('assigned_to', $value);
    # Store the old assignee. check_can_change_field() needs it.
    $self->{'_old_assigned_to'} = $self->{'assigned_to_obj'}->id;
    delete $self->{'assigned_to_obj'};
}
sub reset_assigned_to {
    my $self = shift;
    my $comp = $self->component_obj;
    $self->set_assigned_to($comp->default_assignee);
}
sub set_cclist_accessible { $_[0]->set('cclist_accessible', $_[1]); }
sub set_comment_is_private {
    my ($self, $comment_id, $isprivate) = @_;
    return unless Bugzilla->user->is_insider;
    my ($comment) = grep($comment_id == $_->id, @{ $self->comments });
    ThrowUserError('comment_invalid_isprivate', { id => $comment_id }) 
        if !$comment;

    $isprivate = $isprivate ? 1 : 0;
    if ($isprivate != $comment->is_private) {
        $self->{comment_isprivate} ||= {};
        $self->{comment_isprivate}->{$comment_id} = $isprivate;
    }
}
sub set_component  {
    my ($self, $name) = @_;
    my $old_comp  = $self->component_obj;
    my $component = $self->_check_component($name);
    if ($old_comp->id != $component->id) {
        $self->{component_id}  = $component->id;
        $self->{component}     = $component->name;
        $self->{component_obj} = $component;
        # For update()
        $self->{_old_component_name} = $old_comp->name;
        # Add in the Default CC of the new Component;
        foreach my $cc (@{$component->initial_cc}) {
            $self->add_cc($cc);
        }
    }
}
sub set_custom_field {
    my ($self, $field, $value) = @_;

    if (ref $value eq 'ARRAY' && $field->type != FIELD_TYPE_MULTI_SELECT) {
        $value = $value->[0];
    }
    ThrowCodeError('field_not_custom', { field => $field }) if !$field->custom;
    $self->set($field->name, $value);
}
sub set_deadline { $_[0]->set('deadline', $_[1]); }
sub set_dependencies {
    my ($self, $dependson, $blocked) = @_;
    ($dependson, $blocked) = $self->_check_dependencies($dependson, $blocked);
    # These may already be detainted, but all setters are supposed to
    # detaint their input if they've run a validator (just as though
    # we had used Bugzilla::Object::set), so we do that here.
    detaint_natural($_) foreach (@$dependson, @$blocked);
    $self->{'dependson'} = $dependson;
    $self->{'blocked'}   = $blocked;
}
sub _clear_dup_id { $_[0]->{dup_id} = undef; }
sub set_dup_id {
    my ($self, $dup_id) = @_;
    my $old = $self->dup_id || 0;
    $self->set('dup_id', $dup_id);
    my $new = $self->dup_id;
    return if $old == $new;
    
    # Update the other bug.
    my $dupe_of = new Bugzilla::Bug($self->dup_id);
    if (delete $self->{_add_dup_cc}) {
        $dupe_of->add_cc($self->reporter);
    }
    $dupe_of->add_comment("", { type       => CMT_HAS_DUPE,
                                extra_data => $self->id });
    $self->{_dup_for_update} = $dupe_of;
    
    # Now make sure that we add a duplicate comment on *this* bug.
    # (Change an existing comment into a dup comment, if there is one,
    # or add an empty dup comment.)
    if ($self->{added_comments}) {
        my @normal = grep { !defined $_->{type} || $_->{type} == CMT_NORMAL }
                          @{ $self->{added_comments} };
        # Turn the last one into a dup comment.
        $normal[-1]->{type} = CMT_DUPE_OF;
        $normal[-1]->{extra_data} = $self->dup_id;
    }
    else {
        $self->add_comment('', { type       => CMT_DUPE_OF,
                                 extra_data => $self->dup_id });
    }
}
sub set_estimated_time { $_[0]->set('estimated_time', $_[1]); }
sub _set_everconfirmed { $_[0]->set('everconfirmed', $_[1]); }
sub set_flags {
    my ($self, $flags, $new_flags) = @_;

    Bugzilla::Flag->set_flag($self, $_) foreach (@$flags, @$new_flags);
}
sub set_op_sys         { $_[0]->set('op_sys',        $_[1]); }
sub set_platform       { $_[0]->set('rep_platform',  $_[1]); }
sub set_priority       { $_[0]->set('priority',      $_[1]); }
sub set_product {
    my ($self, $name, $params) = @_;
    my $old_product = $self->product_obj;
    my $product = $self->_check_product($name);
    
    my $product_changed = 0;
    if ($old_product->id != $product->id) {
        $self->{product_id}  = $product->id;
        $self->{product}     = $product->name;
        $self->{product_obj} = $product;
        # For update()
        $self->{_old_product_name} = $old_product->name;
        # Delete fields that depend upon the old Product value.
        delete $self->{choices};
        $product_changed = 1;
    }

    $params ||= {};
    my $comp_name = $params->{component} || $self->component;
    my $vers_name = $params->{version}   || $self->version;
    my $tm_name   = $params->{target_milestone};
    # This way, if usetargetmilestone is off and we've changed products,
    # set_target_milestone will reset our target_milestone to
    # $product->default_milestone. But if we haven't changed products,
    # we don't reset anything.
    if (!defined $tm_name
        && (Bugzilla->params->{'usetargetmilestone'} || !$product_changed))
    {
        $tm_name = $self->target_milestone;
    }

    if ($product_changed && Bugzilla->usage_mode == USAGE_MODE_BROWSER) {
        # Try to set each value with the new product.
        # Have to set error_mode because Throw*Error calls exit() otherwise.
        my $old_error_mode = Bugzilla->error_mode;
        Bugzilla->error_mode(ERROR_MODE_DIE);
        my $component_ok = eval { $self->set_component($comp_name);      1; };
        my $version_ok   = eval { $self->set_version($vers_name);        1; };
        my $milestone_ok = 1;
        # Reporters can move bugs between products but not set the TM.
        if ($self->check_can_change_field('target_milestone', 0, 1)) {
            $milestone_ok = eval { $self->set_target_milestone($tm_name); 1; };
        }
        else {
            # Have to set this directly to bypass the validators.
            $self->{target_milestone} = $product->default_milestone;
        }
        # If there were any errors thrown, make sure we don't mess up any
        # other part of Bugzilla that checks $@.
        undef $@;
        Bugzilla->error_mode($old_error_mode);
        
        my $verified = $params->{change_confirmed};
        my %vars;
        if (!$verified || !$component_ok || !$version_ok || !$milestone_ok) {
            $vars{defaults} = {
                # Note that because of the eval { set } above, these are
                # already set correctly if they're valid, otherwise they're
                # set to some invalid value which the template will ignore.
                component => $self->component,
                version   => $self->version,
                milestone => $milestone_ok ? $self->target_milestone
                                           : $product->default_milestone
            };
            $vars{components} = [map { $_->name } @{$product->components}];
            $vars{milestones} = [map { $_->name } @{$product->milestones}];
            $vars{versions}   = [map { $_->name } @{$product->versions}];
        }

        if (!$verified) {
            $vars{verify_bug_groups} = 1;
            my $dbh = Bugzilla->dbh;
            my @idlist = ($self->id);
            push(@idlist, map {$_->id} @{ $params->{other_bugs} })
                if $params->{other_bugs};
            # Get the ID of groups which are no longer valid in the new product.
            my $gids = $dbh->selectcol_arrayref(
                'SELECT bgm.group_id
                   FROM bug_group_map AS bgm
                  WHERE bgm.bug_id IN (' . join(',', ('?') x @idlist) . ')
                    AND bgm.group_id NOT IN
                        (SELECT gcm.group_id
                           FROM group_control_map AS gcm
                           WHERE gcm.product_id = ?
                                 AND ( (gcm.membercontrol != ?
                                        AND gcm.group_id IN ('
                                        . Bugzilla->user->groups_as_string . '))
                                       OR gcm.othercontrol != ?) )',
                undef, (@idlist, $product->id, CONTROLMAPNA, CONTROLMAPNA));
            $vars{'old_groups'} = Bugzilla::Group->new_from_list($gids);            
        }
        
        if (%vars) {
            $vars{product} = $product;
            $vars{bug} = $self;
            my $template = Bugzilla->template;
            $template->process("bug/process/verify-new-product.html.tmpl",
                \%vars) || ThrowTemplateError($template->error());
            exit;
        }
    }
    else {
        # When we're not in the browser (or we didn't change the product), we
        # just die if any of these are invalid.
        $self->set_component($comp_name);
        $self->set_version($vers_name);
        if ($product_changed && !$self->check_can_change_field('target_milestone', 0, 1)) {
            # Have to set this directly to bypass the validators.
            $self->{target_milestone} = $product->default_milestone;
        }
        else {
            $self->set_target_milestone($tm_name);
        }
    }
    
    if ($product_changed) {
        # Remove groups that aren't valid in the new product. This will also
        # have the side effect of removing the bug from groups that aren't
        # active anymore.
        #
        # We copy this array because the original array is modified while we're
        # working, and that confuses "foreach".
        my @current_groups = @{$self->groups_in};
        foreach my $group (@current_groups) {
            if (!grep($group->id == $_->id, @{$product->groups_valid})) {
                $self->remove_group($group);
            }
        }
    
        # Make sure the bug is in all the mandatory groups for the new product.
        foreach my $group (@{$product->groups_mandatory_for(Bugzilla->user)}) {
            $self->add_group($group);
        }
    }
    
    # XXX This is temporary until all of process_bug uses update();
    return $product_changed;
}

sub set_qa_contact {
    my ($self, $value) = @_;
    $self->set('qa_contact', $value);
    # Store the old QA contact. check_can_change_field() needs it.
    if ($self->{'qa_contact_obj'}) {
        $self->{'_old_qa_contact'} = $self->{'qa_contact_obj'}->id;
    }
    delete $self->{'qa_contact_obj'};
}
sub reset_qa_contact {
    my $self = shift;
    my $comp = $self->component_obj;
    $self->set_qa_contact($comp->default_qa_contact);
}
sub set_remaining_time { $_[0]->set('remaining_time', $_[1]); }
# Used only when closing a bug or moving between closed states.
sub _zero_remaining_time { $_[0]->{'remaining_time'} = 0; }
sub set_reporter_accessible { $_[0]->set('reporter_accessible', $_[1]); }
sub set_resolution {
    my ($self, $value, $params) = @_;
    
    my $old_res = $self->resolution;
    $self->set('resolution', $value);
    delete $self->{choices};
    my $new_res = $self->resolution;

    if ($new_res ne $old_res) {
        # MOVED has a special meaning and can only be used when
        # really moving bugs to another installation.
        ThrowCodeError('no_manual_moved') if ($new_res eq 'MOVED' && !$params->{moving});

        # Clear the dup_id if we're leaving the dup resolution.
        if ($old_res eq 'DUPLICATE') {
            $self->_clear_dup_id();
        }
        # Duplicates should have no remaining time left.
        elsif ($new_res eq 'DUPLICATE' && $self->remaining_time != 0) {
            $self->_zero_remaining_time();
        }
    }
    
    # We don't check if we're entering or leaving the dup resolution here,
    # because we could be moving from being a dup of one bug to being a dup
    # of another, theoretically. Note that this code block will also run
    # when going between different closed states.
    if ($self->resolution eq 'DUPLICATE') {
        if ($params->{dupe_of}) {
            $self->set_dup_id($params->{dupe_of});
        }
        elsif (!$self->dup_id) {
            ThrowUserError('dupe_id_required');
        }
    }
}
sub clear_resolution {
    my $self = shift;
    if (!$self->status->is_open) {
        ThrowUserError('resolution_cant_clear', { bug_id => $self->id });
    }
    $self->{'resolution'} = ''; 
    $self->_clear_dup_id; 
}
sub set_severity       { $_[0]->set('bug_severity',  $_[1]); }
sub set_status {
    my ($self, $status, $params) = @_;
    my $old_status = $self->status;
    $self->set('bug_status', $status);
    delete $self->{'status'};
    delete $self->{'statuses_available'};
    delete $self->{'choices'};
    my $new_status = $self->status;
    
    if ($new_status->is_open) {
        # Check for the everconfirmed transition
        $self->_set_everconfirmed($new_status->name eq 'UNCONFIRMED' ? 0 : 1);
        $self->clear_resolution();
    }
    else {
        # We do this here so that we can make sure closed statuses have
        # resolutions.
        my $resolution = delete $params->{resolution} || $self->resolution;
        $self->set_resolution($resolution, $params);

        # Changing between closed statuses zeros the remaining time.
        if ($new_status->id != $old_status->id && $self->remaining_time != 0) {
            $self->_zero_remaining_time();
        }
    }
}
sub set_status_whiteboard { $_[0]->set('status_whiteboard', $_[1]); }
sub set_summary           { $_[0]->set('short_desc',        $_[1]); }
sub set_target_milestone  { $_[0]->set('target_milestone',  $_[1]); }
sub set_url               { $_[0]->set('bug_file_loc',      $_[1]); }
sub set_version           { $_[0]->set('version',           $_[1]); }

########################
# "Add/Remove" Methods #
########################

# These are in alphabetical order by field name.

# Accepts a User object or a username. Adds the user only if they
# don't already exist as a CC on the bug.
sub add_cc {
    my ($self, $user_or_name) = @_;
    return if !$user_or_name;
    my $user = ref $user_or_name ? $user_or_name
                                 : Bugzilla::User->check($user_or_name);
    $self->_check_strict_isolation_for_user($user);
    my $cc_users = $self->cc_users;
    push(@$cc_users, $user) if !grep($_->id == $user->id, @$cc_users);
}

# Accepts a User object or a username. Removes the User if they exist
# in the list, but doesn't throw an error if they don't exist.
sub remove_cc {
    my ($self, $user_or_name) = @_;
    my $user = ref $user_or_name ? $user_or_name
                                 : Bugzilla::User->check($user_or_name);
    my $cc_users = $self->cc_users;
    @$cc_users = grep { $_->id != $user->id } @$cc_users;
}

# $bug->add_comment("comment", {isprivate => 1, work_time => 10.5,
#                               type => CMT_NORMAL, extra_data => $data});
sub add_comment {
    my ($self, $comment, $params) = @_;

    $comment = $self->_check_comment($comment);

    $params ||= {};
    if (exists $params->{work_time}) {
        $params->{work_time} = $self->_check_work_time($params->{work_time});
        ThrowUserError('comment_required')
            if $comment eq '' && $params->{work_time} != 0;
    }
    if (exists $params->{type}) {
        $params->{type} = $self->_check_comment_type($params->{type});
    }
    if (exists $params->{isprivate}) {
        $params->{isprivate} = 
            $self->_check_commentprivacy($params->{isprivate});
    }
    # XXX We really should check extra_data, too.

    if ($comment eq '' && !($params->{type} || $params->{work_time})) {
        return;
    }

    # So we really want to comment. Make sure we are allowed to do so.
    my $privs;
    $self->check_can_change_field('longdesc', 0, 1, \$privs)
        || ThrowUserError('illegal_change', { field => 'longdesc', privs => $privs });

    $self->{added_comments} ||= [];
    my $add_comment = dclone($params);
    $add_comment->{thetext} = $comment;

    # We only want to trick_taint fields that we know about--we don't
    # want to accidentally let somebody set some field that's not OK
    # to set!
    foreach my $field (UPDATE_COMMENT_COLUMNS) {
        trick_taint($add_comment->{$field}) if defined $add_comment->{$field};
    }

    push(@{$self->{added_comments}}, $add_comment);
}

# There was a lot of duplicate code when I wrote this as three separate
# functions, so I just combined them all into one. This is also easier for
# process_bug to use.
sub modify_keywords {
    my ($self, $keywords, $action) = @_;
    
    $action ||= "makeexact";
    if (!grep($action eq $_, qw(add delete makeexact))) {
        $action = "makeexact";
    }
    
    $keywords = $self->_check_keywords($keywords);

    my (@result, $any_changes);
    if ($action eq 'makeexact') {
        @result = @$keywords;
        # Check if anything was added or removed.
        my @old_ids = map { $_->id } @{$self->keyword_objects};
        my @new_ids = map { $_->id } @result;
        my ($removed, $added) = diff_arrays(\@old_ids, \@new_ids);
        $any_changes = scalar @$removed || scalar @$added;
    }
    else {
        # We're adding or deleting specific keywords.
        my %keys = map {$_->id => $_} @{$self->keyword_objects};
        if ($action eq 'add') {
            $keys{$_->id} = $_ foreach @$keywords;
        }
        else {
            delete $keys{$_->id} foreach @$keywords;
        }
        @result = values %keys;
        $any_changes = scalar @$keywords;
    }
    # Make sure we retain the sort order.
    @result = sort {lc($a->name) cmp lc($b->name)} @result;
    
    if ($any_changes) {
        my $privs;
        my $new = join(', ', (map {$_->name} @result));
        my $check = $self->check_can_change_field('keywords', 0, 1, \$privs)
            || ThrowUserError('illegal_change', { field    => 'keywords',
                                                  oldvalue => $self->keywords,
                                                  newvalue => $new,
                                                  privs    => $privs });
    }

    $self->{'keyword_objects'} = \@result;
    return $any_changes;
}

sub add_group {
    my ($self, $group) = @_;
    # Invalid ids are silently ignored. (We can't tell people whether
    # or not a group exists.)
    $group = new Bugzilla::Group($group) unless ref $group;
    return unless $group;

    return if !$group->is_active or !$group->is_bug_group;

    # Make sure that bugs in this product can actually be restricted
    # to this group.
    grep($group->id == $_->id, @{$self->product_obj->groups_valid})
         || ThrowUserError('group_invalid_restriction',
                { product => $self->product, group_id => $group->id });

    # OtherControl people can add groups only during a product change,
    # and only when the group is not NA for them.
    if (!Bugzilla->user->in_group($group->name)) {
        my $controls = $self->product_obj->group_controls->{$group->id};
        if (!$self->{_old_product_name}
            || $controls->{othercontrol} == CONTROLMAPNA)
        {
            ThrowUserError('group_change_denied',
                           { bug => $self, group_id => $group->id });
        }
    }

    my $current_groups = $self->groups_in;
    if (!grep($group->id == $_->id, @$current_groups)) {
        push(@$current_groups, $group);
    }
}

sub remove_group {
    my ($self, $group) = @_;
    $group = new Bugzilla::Group($group) unless ref $group;
    return unless $group;
    
    # First, check if this is a valid group for this product.
    # You can *always* remove a group that is not valid for this product, so
    # we don't do any other checks if that's the case. (set_product does this.)
    #
    # This particularly happens when isbuggroup is no longer 1, and we're
    # moving a bug to a new product.
    if (grep($_->id == $group->id, @{$self->product_obj->groups_valid})) {   
        my $controls = $self->product_obj->group_controls->{$group->id};

        # Nobody can ever remove a Mandatory group.
        if ($controls->{membercontrol} == CONTROLMAPMANDATORY) {
            ThrowUserError('group_invalid_removal',
                { product => $self->product, group_id => $group->id,
                  bug => $self });
        }

        # OtherControl people can remove groups only during a product change,
        # and only when they are non-Mandatory and non-NA.
        if (!Bugzilla->user->in_group($group->name)) {
            if (!$self->{_old_product_name}
                || $controls->{othercontrol} == CONTROLMAPMANDATORY
                || $controls->{othercontrol} == CONTROLMAPNA)
            {
                ThrowUserError('group_change_denied',
                               { bug => $self, group_id => $group->id });
            }
        }
    }
    
    my $current_groups = $self->groups_in;
    @$current_groups = grep { $_->id != $group->id } @$current_groups;
}

sub add_see_also {
    my ($self, $input) = @_;
    $input = trim($input);

    # We assume that the URL is an HTTP URL if there is no (something):// 
    # in front.
    my $uri = new URI($input);
    if (!$uri->scheme) {
        # This works better than setting $uri->scheme('http'), because
        # that creates URLs like "http:domain.com" and doesn't properly
        # differentiate the path from the domain.
        $uri = new URI("http://$input");
    }
    elsif ($uri->scheme ne 'http' && $uri->scheme ne 'https') {
        ThrowUserError('bug_url_invalid', { url => $input, reason => 'http' });
    }

    my $result;
    # Launchpad URLs
    if ($uri->authority =~ /launchpad.net$/) {
        # Launchpad bug URLs can look like various things:
        #   https://bugs.launchpad.net/ubuntu/+bug/1234
        #   https://launchpad.net/bugs/1234
        # All variations end with either "/bugs/1234" or "/+bug/1234"
        if ($uri->path =~ m|bugs?/(\d+)$|) {
            # This is the shortest standard URL form for Launchpad bugs,
            # and so we reduce all URLs to this.
            $result = "https://launchpad.net/bugs/$1";
        }
        else {
            ThrowUserError('bug_url_invalid',
                           { url => $input, reason => 'id' });
        }
    }
    # Bugzilla URLs
    else {
        if ($uri->path !~ /show_bug\.cgi$/) {
            ThrowUserError('bug_url_invalid', 
                           { url => $input, reason => 'show_bug' });
        }

        my $bug_id = $uri->query_param('id');
        # We don't currently allow aliases, because we can't check to see
        # if somebody's putting both an alias link and a numeric ID link.
        # When we start validating the URL by accessing the other Bugzilla,
        # we can allow aliases.
        detaint_natural($bug_id);
        if (!$bug_id) {
            ThrowUserError('bug_url_invalid', 
                           { url => $input, reason => 'id' });
        }

        # Make sure that "id" is the only query parameter.
        $uri->query("id=$bug_id");
        # And remove any # part if there is one.
        $uri->fragment(undef);
        $result = $uri->canonical->as_string;
    }

    if (length($result) > MAX_BUG_URL_LENGTH) {
        ThrowUserError('bug_url_too_long', { url => $result });
    }

    # We only add the new URI if it hasn't been added yet. URIs are
    # case-sensitive, but most of our DBs are case-insensitive, so we do
    # this check case-insensitively.
    if (!grep { lc($_) eq lc($result) } @{ $self->see_also }) {
        my $privs;
        my $can = $self->check_can_change_field('see_also', '', $result, \$privs);
        if (!$can) {
            ThrowUserError('illegal_change', { field    => 'see_also',
                                               newvalue => $result,
                                               privs    => $privs });
        }

        push(@{ $self->see_also }, $result);
    }
}

sub remove_see_also {
    my ($self, $url) = @_;
    my $see_also = $self->see_also;
    my @new_see_also = grep { lc($_) ne lc($url) } @$see_also;
    my $privs;
    my $can = $self->check_can_change_field('see_also', $see_also, \@new_see_also, \$privs);
    if (!$can) {
        ThrowUserError('illegal_change', { field    => 'see_also',
                                           oldvalue => $url,
                                           privs    => $privs });
        }
    $self->{see_also} = \@new_see_also;
}

#####################################################################
# Instance Accessors
#####################################################################

# These subs are in alphabetical order, as much as possible.
# If you add a new sub, please try to keep it in alphabetical order
# with the other ones.

# Note: If you add a new method, remember that you must check the error
# state of the bug before returning any data. If $self->{error} is
# defined, then return something empty. Otherwise you risk potential
# security holes.

sub dup_id {
    my ($self) = @_;
    return $self->{'dup_id'} if exists $self->{'dup_id'};

    $self->{'dup_id'} = undef;
    return if $self->{'error'};

    if ($self->{'resolution'} eq 'DUPLICATE') { 
        my $dbh = Bugzilla->dbh;
        $self->{'dup_id'} =
          $dbh->selectrow_array(q{SELECT dupe_of 
                                  FROM duplicates
                                  WHERE dupe = ?},
                                undef,
                                $self->{'bug_id'});
    }
    return $self->{'dup_id'};
}

sub actual_time {
    my ($self) = @_;
    return $self->{'actual_time'} if exists $self->{'actual_time'};

    if ( $self->{'error'} || !Bugzilla->user->is_timetracker ) {
        $self->{'actual_time'} = undef;
        return $self->{'actual_time'};
    }

    my $sth = Bugzilla->dbh->prepare("SELECT SUM(work_time)
                                      FROM longdescs 
                                      WHERE longdescs.bug_id=?");
    $sth->execute($self->{bug_id});
    $self->{'actual_time'} = $sth->fetchrow_array();
    return $self->{'actual_time'};
}

sub any_flags_requesteeble {
    my ($self) = @_;
    return $self->{'any_flags_requesteeble'} 
        if exists $self->{'any_flags_requesteeble'};
    return 0 if $self->{'error'};

    my $any_flags_requesteeble =
      grep { $_->is_requestable && $_->is_requesteeble } @{$self->flag_types};
    # Useful in case a flagtype is no longer requestable but a requestee
    # has been set before we turned off that bit.
    $any_flags_requesteeble ||= grep { $_->requestee_id } @{$self->flags};
    $self->{'any_flags_requesteeble'} = $any_flags_requesteeble;

    return $self->{'any_flags_requesteeble'};
}

sub attachments {
    my ($self) = @_;
    return $self->{'attachments'} if exists $self->{'attachments'};
    return [] if $self->{'error'};

    $self->{'attachments'} =
        Bugzilla::Attachment->get_attachments_by_bug($self->bug_id, {preload => 1});
    return $self->{'attachments'};
}

sub assigned_to {
    my ($self) = @_;
    return $self->{'assigned_to_obj'} if exists $self->{'assigned_to_obj'};
    $self->{'assigned_to'} = 0 if $self->{'error'};
    $self->{'assigned_to_obj'} ||= new Bugzilla::User($self->{'assigned_to'});
    return $self->{'assigned_to_obj'};
}

sub blocked {
    my ($self) = @_;
    return $self->{'blocked'} if exists $self->{'blocked'};
    return [] if $self->{'error'};
    $self->{'blocked'} = EmitDependList("dependson", "blocked", $self->bug_id);
    return $self->{'blocked'};
}

# Even bugs in an error state always have a bug_id.
sub bug_id { $_[0]->{'bug_id'}; }

sub cc {
    my ($self) = @_;
    return $self->{'cc'} if exists $self->{'cc'};
    return [] if $self->{'error'};

    my $dbh = Bugzilla->dbh;
    $self->{'cc'} = $dbh->selectcol_arrayref(
        q{SELECT profiles.login_name FROM cc, profiles
           WHERE bug_id = ?
             AND cc.who = profiles.userid
        ORDER BY profiles.login_name},
      undef, $self->bug_id);

    $self->{'cc'} = undef if !scalar(@{$self->{'cc'}});

    return $self->{'cc'};
}

# XXX Eventually this will become the standard "cc" method used everywhere.
sub cc_users {
    my $self = shift;
    return $self->{'cc_users'} if exists $self->{'cc_users'};
    return [] if $self->{'error'};
    
    my $dbh = Bugzilla->dbh;
    my $cc_ids = $dbh->selectcol_arrayref(
        'SELECT who FROM cc WHERE bug_id = ?', undef, $self->id);
    $self->{'cc_users'} = Bugzilla::User->new_from_list($cc_ids);
    return $self->{'cc_users'};
}

sub component {
    my ($self) = @_;
    return $self->{component} if exists $self->{component};
    return '' if $self->{error};
    ($self->{component}) = Bugzilla->dbh->selectrow_array(
        'SELECT name FROM components WHERE id = ?',
        undef, $self->{component_id});
    return $self->{component};
}

# XXX Eventually this will replace component()
sub component_obj {
    my ($self) = @_;
    return $self->{component_obj} if defined $self->{component_obj};
    return {} if $self->{error};
    $self->{component_obj} = new Bugzilla::Component($self->{component_id});
    return $self->{component_obj};
}

sub classification_id {
    my ($self) = @_;
    return $self->{classification_id} if exists $self->{classification_id};
    return 0 if $self->{error};
    ($self->{classification_id}) = Bugzilla->dbh->selectrow_array(
        'SELECT classification_id FROM products WHERE id = ?',
        undef, $self->{product_id});
    return $self->{classification_id};
}

sub classification {
    my ($self) = @_;
    return $self->{classification} if exists $self->{classification};
    return '' if $self->{error};
    ($self->{classification}) = Bugzilla->dbh->selectrow_array(
        'SELECT name FROM classifications WHERE id = ?',
        undef, $self->classification_id);
    return $self->{classification};
}

sub dependson {
    my ($self) = @_;
    return $self->{'dependson'} if exists $self->{'dependson'};
    return [] if $self->{'error'};
    $self->{'dependson'} = 
        EmitDependList("blocked", "dependson", $self->bug_id);
    return $self->{'dependson'};
}

sub flag_types {
    my ($self) = @_;
    return $self->{'flag_types'} if exists $self->{'flag_types'};
    return [] if $self->{'error'};

    my $vars = { target_type  => 'bug',
                 product_id   => $self->{product_id},
                 component_id => $self->{component_id},
                 bug_id       => $self->bug_id };

    $self->{'flag_types'} = Bugzilla::Flag->_flag_types($vars);
    return $self->{'flag_types'};
}

sub flags {
    my $self = shift;

    # Don't cache it as it must be in sync with ->flag_types.
    $self->{flags} = [map { @{$_->{flags}} } @{$self->flag_types}];
    return $self->{flags};
}

sub isopened {
    my $self = shift;
    return is_open_state($self->{bug_status}) ? 1 : 0;
}

sub keywords {
    my ($self) = @_;
    return join(', ', (map { $_->name } @{$self->keyword_objects}));
}

# XXX At some point, this should probably replace the normal "keywords" sub.
sub keyword_objects {
    my $self = shift;
    return $self->{'keyword_objects'} if defined $self->{'keyword_objects'};
    return [] if $self->{'error'};

    my $dbh = Bugzilla->dbh;
    my $ids = $dbh->selectcol_arrayref(
         "SELECT keywordid FROM keywords WHERE bug_id = ?", undef, $self->id);
    $self->{'keyword_objects'} = Bugzilla::Keyword->new_from_list($ids);
    return $self->{'keyword_objects'};
}

sub comments {
    my ($self, $params) = @_;
    return [] if $self->{'error'};
    $params ||= {};

    if (!defined $self->{'comments'}) {
        $self->{'comments'} = Bugzilla::Comment->match({ bug_id => $self->id });
        my $count = 0;
        foreach my $comment (@{ $self->{'comments'} }) {
            $comment->{count} = $count++;
            $comment->{bug} = $self;
        }
    }
    my @comments = @{ $self->{'comments'} };

    my $order = $params->{order} 
        || Bugzilla->user->settings->{'comment_sort_order'}->{'value'};
    if ($order ne 'oldest_to_newest') {
        @comments = reverse @comments;
        if ($order eq 'newest_to_oldest_desc_first') {
            unshift(@comments, pop @comments);
        }
    }

    if ($params->{after}) {
        my $from = datetime_from($params->{after});
        @comments = grep { datetime_from($_->creation_ts) > $from } @comments;
    }
    if ($params->{to}) {
        my $to = datetime_from($params->{to});
        @comments = grep { datetime_from($_->creation_ts) <= $to } @comments;
    }
    return \@comments;
}

sub product {
    my ($self) = @_;
    return $self->{product} if exists $self->{product};
    return '' if $self->{error};
    ($self->{product}) = Bugzilla->dbh->selectrow_array(
        'SELECT name FROM products WHERE id = ?',
        undef, $self->{product_id});
    return $self->{product};
}

# XXX This should eventually replace the "product" subroutine.
sub product_obj {
    my $self = shift;
    return {} if $self->{error};
    $self->{product_obj} ||= new Bugzilla::Product($self->{product_id});
    return $self->{product_obj};
}

sub qa_contact {
    my ($self) = @_;
    return $self->{'qa_contact_obj'} if exists $self->{'qa_contact_obj'};
    return undef if $self->{'error'};

    if (Bugzilla->params->{'useqacontact'} && $self->{'qa_contact'}) {
        $self->{'qa_contact_obj'} = new Bugzilla::User($self->{'qa_contact'});
    } else {
        # XXX - This is somewhat inconsistent with the assignee/reporter 
        # methods, which will return an empty User if they get a 0. 
        # However, we're keeping it this way now, for backwards-compatibility.
        $self->{'qa_contact_obj'} = undef;
    }
    return $self->{'qa_contact_obj'};
}

sub reporter {
    my ($self) = @_;
    return $self->{'reporter'} if exists $self->{'reporter'};
    $self->{'reporter_id'} = 0 if $self->{'error'};
    $self->{'reporter'} = new Bugzilla::User($self->{'reporter_id'});
    return $self->{'reporter'};
}

sub see_also {
    my ($self) = @_;
    return [] if $self->{'error'};
    $self->{'see_also'} ||= Bugzilla->dbh->selectcol_arrayref(
        'SELECT value FROM bug_see_also WHERE bug_id = ?', undef, $self->id);
    return $self->{'see_also'};
}

sub status {
    my $self = shift;
    return undef if $self->{'error'};

    $self->{'status'} ||= new Bugzilla::Status({name => $self->{'bug_status'}});
    return $self->{'status'};
}

sub statuses_available {
    my $self = shift;
    return [] if $self->{'error'};
    return $self->{'statuses_available'}
        if defined $self->{'statuses_available'};

    my @statuses = @{ $self->status->can_change_to };

    # UNCONFIRMED is only a valid status if it is enabled in this product.
    if (!$self->product_obj->allows_unconfirmed) {
        @statuses = grep { $_->name ne 'UNCONFIRMED' } @statuses;
    }

    my @available;
    foreach my $status (@statuses) {
        # Make sure this is a legal status transition
        next if !$self->check_can_change_field(
                     'bug_status', $self->status->name, $status->name);
        push(@available, $status);
    }

    # If this bug has an inactive status set, it should still be in the list.
    if (!grep($_->name eq $self->status->name, @available)) {
        unshift(@available, $self->status);
    }

    $self->{'statuses_available'} = \@available;
    return $self->{'statuses_available'};
}

sub show_attachment_flags {
    my ($self) = @_;
    return $self->{'show_attachment_flags'} 
        if exists $self->{'show_attachment_flags'};
    return 0 if $self->{'error'};

    # The number of types of flags that can be set on attachments to this bug
    # and the number of flags on those attachments.  One of these counts must be
    # greater than zero in order for the "flags" column to appear in the table
    # of attachments.
    my $num_attachment_flag_types = Bugzilla::FlagType::count(
        { 'target_type'  => 'attachment',
          'product_id'   => $self->{'product_id'},
          'component_id' => $self->{'component_id'} });
    my $num_attachment_flags = Bugzilla::Flag->count(
        { 'target_type'  => 'attachment',
          'bug_id'       => $self->bug_id });

    $self->{'show_attachment_flags'} =
        ($num_attachment_flag_types || $num_attachment_flags);

    return $self->{'show_attachment_flags'};
}

sub use_votes {
    my ($self) = @_;
    return 0 if $self->{'error'};

    return Bugzilla->params->{'usevotes'} 
           && $self->product_obj->votes_per_user > 0;
}

sub groups {
    my $self = shift;
    return $self->{'groups'} if exists $self->{'groups'};
    return [] if $self->{'error'};

    my $dbh = Bugzilla->dbh;
    my @groups;

    # Some of this stuff needs to go into Bugzilla::User

    # For every group, we need to know if there is ANY bug_group_map
    # record putting the current bug in that group and if there is ANY
    # user_group_map record putting the user in that group.
    # The LEFT JOINs are checking for record existence.
    #
    my $grouplist = Bugzilla->user->groups_as_string;
    my $sth = $dbh->prepare(
             "SELECT DISTINCT groups.id, name, description," .
             " CASE WHEN bug_group_map.group_id IS NOT NULL" .
             " THEN 1 ELSE 0 END," .
             " CASE WHEN groups.id IN($grouplist) THEN 1 ELSE 0 END," .
             " isactive, membercontrol, othercontrol" .
             " FROM groups" . 
             " LEFT JOIN bug_group_map" .
             " ON bug_group_map.group_id = groups.id" .
             " AND bug_id = ?" .
             " LEFT JOIN group_control_map" .
             " ON group_control_map.group_id = groups.id" .
             " AND group_control_map.product_id = ? " .
             " WHERE isbuggroup = 1" .
             " ORDER BY description");
    $sth->execute($self->{'bug_id'},
                  $self->{'product_id'});

    while (my ($groupid, $name, $description, $ison, $ingroup, $isactive,
            $membercontrol, $othercontrol) = $sth->fetchrow_array()) {

        $membercontrol ||= 0;

        # For product groups, we only want to use the group if either
        # (1) The bit is set and not required, or
        # (2) The group is Shown or Default for members and
        #     the user is a member of the group.
        if ($ison ||
            ($isactive && $ingroup
                       && (($membercontrol == CONTROLMAPDEFAULT)
                           || ($membercontrol == CONTROLMAPSHOWN))
            ))
        {
            my $ismandatory = $isactive
              && ($membercontrol == CONTROLMAPMANDATORY);

            push (@groups, { "bit" => $groupid,
                             "name" => $name,
                             "ison" => $ison,
                             "ingroup" => $ingroup,
                             "mandatory" => $ismandatory,
                             "description" => $description });
        }
    }

    $self->{'groups'} = \@groups;

    return $self->{'groups'};
}

sub groups_in {
    my $self = shift;
    return $self->{'groups_in'} if exists $self->{'groups_in'};
    return [] if $self->{'error'};
    my $group_ids = Bugzilla->dbh->selectcol_arrayref(
        'SELECT group_id FROM bug_group_map WHERE bug_id = ?',
        undef, $self->id);
    $self->{'groups_in'} = Bugzilla::Group->new_from_list($group_ids);
    return $self->{'groups_in'};
}

sub user {
    my $self = shift;
    return $self->{'user'} if exists $self->{'user'};
    return {} if $self->{'error'};

    my $user = Bugzilla->user;
    my $canmove = Bugzilla->params->{'move-enabled'} && $user->is_mover;

    my $prod_id = $self->{'product_id'};

    my $unknown_privileges = $user->in_group('editbugs', $prod_id);
    my $canedit = $unknown_privileges
                  || $user->id == $self->{'assigned_to'}
                  || (Bugzilla->params->{'useqacontact'}
                      && $self->{'qa_contact'}
                      && $user->id == $self->{'qa_contact'});
    my $canconfirm = $unknown_privileges
                     || $user->in_group('canconfirm', $prod_id);
    my $isreporter = $user->id
                     && $user->id == $self->{reporter_id};

    $self->{'user'} = {canmove    => $canmove,
                       canconfirm => $canconfirm,
                       canedit    => $canedit,
                       isreporter => $isreporter};
    return $self->{'user'};
}

# This is intended to get values that can be selected by the user in the
# UI. It should not be used for security or validation purposes.
sub choices {
    my $self = shift;
    return $self->{'choices'} if exists $self->{'choices'};
    return {} if $self->{'error'};
    my $user = Bugzilla->user;

    my @products = @{ $user->get_enterable_products };
    # The current product is part of the popup, even if new bugs are no longer
    # allowed for that product
    if (!grep($_->name eq $self->product_obj->name, @products)) {
        unshift(@products, $self->product_obj);
    }

    my %choices = (
        bug_status => $self->statuses_available,
        product    => \@products,
        component  => $self->product_obj->components,
        version    => $self->product_obj->versions,
        target_milestone => $self->product_obj->milestones,
    );

    my $resolution_field = new Bugzilla::Field({ name => 'resolution' });
    # Don't include the empty resolution in drop-downs.
    my @resolutions = grep($_->name, @{ $resolution_field->legal_values });
    # And don't include MOVED in the list unless the bug is already MOVED.
    if ($self->resolution ne 'MOVED') {
        @resolutions= grep { $_->name ne 'MOVED' } @resolutions;
    }
    $choices{'resolution'} = \@resolutions;

    $self->{'choices'} = \%choices;
    return $self->{'choices'};
}

sub votes {
    my ($self) = @_;
    return 0 if $self->{error};
    return $self->{votes} if defined $self->{votes};

    my $dbh = Bugzilla->dbh;
    $self->{votes} = $dbh->selectrow_array(
        'SELECT SUM(vote_count) FROM votes
          WHERE bug_id = ? ' . $dbh->sql_group_by('bug_id'),
        undef, $self->bug_id);
    $self->{votes} ||= 0;
    return $self->{votes};
}

# Convenience Function. If you need speed, use this. If you need
# other Bug fields in addition to this, just create a new Bug with
# the alias.
# Queries the database for the bug with a given alias, and returns
# the ID of the bug if it exists or the undefined value if it doesn't.
sub bug_alias_to_id {
    my ($alias) = @_;
    return undef unless Bugzilla->params->{"usebugaliases"};
    my $dbh = Bugzilla->dbh;
    trick_taint($alias);
    return $dbh->selectrow_array(
        "SELECT bug_id FROM bugs WHERE alias = ?", undef, $alias);
}

#####################################################################
# Subroutines
#####################################################################

# Represents which fields from the bugs table are handled by process_bug.cgi.
sub editable_bug_fields {
    my @fields = Bugzilla->dbh->bz_table_columns('bugs');
    # Obsolete custom fields are not editable.
    my @obsolete_fields = Bugzilla->get_fields({obsolete => 1, custom => 1});
    @obsolete_fields = map { $_->name } @obsolete_fields;
    foreach my $remove ("bug_id", "reporter", "creation_ts", "delta_ts", "lastdiffed", @obsolete_fields) {
        my $location = lsearch(\@fields, $remove);
        # Custom multi-select fields are not stored in the bugs table.
        splice(@fields, $location, 1) if ($location > -1);
    }
    # Sorted because the old @::log_columns variable, which this replaces,
    # was sorted.
    return sort(@fields);
}

# XXX - When Bug::update() will be implemented, we should make this routine
#       a private method.
# Join with bug_status and bugs tables to show bugs with open statuses first,
# and then the others
sub EmitDependList {
    my ($myfield, $targetfield, $bug_id) = (@_);
    my $dbh = Bugzilla->dbh;
    my $list_ref = $dbh->selectcol_arrayref(
          "SELECT $targetfield
             FROM dependencies
                  INNER JOIN bugs ON dependencies.$targetfield = bugs.bug_id
                  INNER JOIN bug_status ON bugs.bug_status = bug_status.value
            WHERE $myfield = ?
            ORDER BY is_open DESC, $targetfield",
            undef, $bug_id);
    return $list_ref;
}

sub ValidateTime {
    my ($time, $field) = @_;

    # regexp verifies one or more digits, optionally followed by a period and
    # zero or more digits, OR we have a period followed by one or more digits
    # (allow negatives, though, so people can back out errors in time reporting)
    if ($time !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/) {
        ThrowUserError("number_not_numeric",
                       {field => "$field", num => "$time"});
    }

    # Only the "work_time" field is allowed to contain a negative value.
    if ( ($time < 0) && ($field ne "work_time") ) {
        ThrowUserError("number_too_small",
                       {field => "$field", num => "$time", min_num => "0"});
    }

    if ($time > 99999.99) {
        ThrowUserError("number_too_large",
                       {field => "$field", num => "$time", max_num => "99999.99"});
    }
}

# Get the activity of a bug, starting from $starttime (if given).
# This routine assumes Bugzilla::Bug->check has been previously called.
sub GetBugActivity {
    my ($bug_id, $attach_id, $starttime) = @_;
    my $dbh = Bugzilla->dbh;

    # Arguments passed to the SQL query.
    my @args = ($bug_id);

    # Only consider changes since $starttime, if given.
    my $datepart = "";
    if (defined $starttime) {
        trick_taint($starttime);
        push (@args, $starttime);
        $datepart = "AND bugs_activity.bug_when > ?";
    }

    my $attachpart = "";
    if ($attach_id) {
        push(@args, $attach_id);
        $attachpart = "AND bugs_activity.attach_id = ?";
    }

    # Only includes attachments the user is allowed to see.
    my $suppjoins = "";
    my $suppwhere = "";
    if (!Bugzilla->user->is_insider) 
    {
        $suppjoins = "LEFT JOIN attachments 
                   ON attachments.attach_id = bugs_activity.attach_id";
        $suppwhere = "AND COALESCE(attachments.isprivate, 0) = 0";
    }

    my $query = "SELECT fielddefs.name, bugs_activity.attach_id, " .
        $dbh->sql_date_format('bugs_activity.bug_when', '%Y.%m.%d %H:%i:%s') .
            ", bugs_activity.removed, bugs_activity.added, profiles.login_name
          FROM bugs_activity
               $suppjoins
     LEFT JOIN fielddefs
            ON bugs_activity.fieldid = fielddefs.id
    INNER JOIN profiles
            ON profiles.userid = bugs_activity.who
         WHERE bugs_activity.bug_id = ?
               $datepart
               $attachpart
               $suppwhere
      ORDER BY bugs_activity.bug_when";

    my $list = $dbh->selectall_arrayref($query, undef, @args);

    my @operations;
    my $operation = {};
    my $changes = [];
    my $incomplete_data = 0;

    foreach my $entry (@$list) {
        my ($fieldname, $attachid, $when, $removed, $added, $who) = @$entry;
        my %change;
        my $activity_visible = 1;

        # check if the user should see this field's activity
        if ($fieldname eq 'remaining_time'
            || $fieldname eq 'estimated_time'
            || $fieldname eq 'work_time'
            || $fieldname eq 'deadline')
        {
            $activity_visible = Bugzilla->user->is_timetracker;
        } else {
            $activity_visible = 1;
        }

        if ($activity_visible) {
            # Check for the results of an old Bugzilla data corruption bug
            $incomplete_data = 1 if ($added =~ /^\?/ || $removed =~ /^\?/);

            # An operation, done by 'who' at time 'when', has a number of
            # 'changes' associated with it.
            # If this is the start of a new operation, store the data from the
            # previous one, and set up the new one.
            if ($operation->{'who'}
                && ($who ne $operation->{'who'}
                    || $when ne $operation->{'when'}))
            {
                $operation->{'changes'} = $changes;
                push (@operations, $operation);

                # Create new empty anonymous data structures.
                $operation = {};
                $changes = [];
            }

            $operation->{'who'} = $who;
            $operation->{'when'} = $when;

            $change{'fieldname'} = $fieldname;
            $change{'attachid'} = $attachid;
            $change{'removed'} = $removed;
            $change{'added'} = $added;
            push (@$changes, \%change);
        }
    }

    if ($operation->{'who'}) {
        $operation->{'changes'} = $changes;
        push (@operations, $operation);
    }

    return(\@operations, $incomplete_data);
}

# Update the bugs_activity table to reflect changes made in bugs.
sub LogActivityEntry {
    my ($i, $col, $removed, $added, $whoid, $timestamp) = @_;
    my $dbh = Bugzilla->dbh;
    # in the case of CCs, deps, and keywords, there's a possibility that someone
    # might try to add or remove a lot of them at once, which might take more
    # space than the activity table allows.  We'll solve this by splitting it
    # into multiple entries if it's too long.
    while ($removed || $added) {
        my ($removestr, $addstr) = ($removed, $added);
        if (length($removestr) > MAX_LINE_LENGTH) {
            my $commaposition = find_wrap_point($removed, MAX_LINE_LENGTH);
            $removestr = substr($removed, 0, $commaposition);
            $removed = substr($removed, $commaposition);
            $removed =~ s/^[,\s]+//; # remove any comma or space
        } else {
            $removed = ""; # no more entries
        }
        if (length($addstr) > MAX_LINE_LENGTH) {
            my $commaposition = find_wrap_point($added, MAX_LINE_LENGTH);
            $addstr = substr($added, 0, $commaposition);
            $added = substr($added, $commaposition);
            $added =~ s/^[,\s]+//; # remove any comma or space
        } else {
            $added = ""; # no more entries
        }
        trick_taint($addstr);
        trick_taint($removestr);
        my $fieldid = get_field_id($col);
        $dbh->do("INSERT INTO bugs_activity
                  (bug_id, who, bug_when, fieldid, removed, added)
                  VALUES (?, ?, ?, ?, ?, ?)",
                  undef, ($i, $whoid, $timestamp, $fieldid, $removestr, $addstr));
    }
}

# Convert WebService API and email_in.pl field names to internal DB field
# names.
sub map_fields {
    my ($params) = @_; 

    my %field_values;
    foreach my $field (keys %$params) {
        my $field_name = FIELD_MAP->{$field} || $field;
        $field_values{$field_name} = $params->{$field};
    }

    # This protects the WebService Bug.search method.
    unless (Bugzilla->user->is_timetracker) {
        delete @field_values{qw(estimated_time remaining_time deadline)};
    }
    
    return \%field_values;
}

# CountOpenDependencies counts the number of open dependent bugs for a
# list of bugs and returns a list of bug_id's and their dependency count
# It takes one parameter:
#  - A list of bug numbers whose dependencies are to be checked
sub CountOpenDependencies {
    my (@bug_list) = @_;
    my @dependencies;
    my $dbh = Bugzilla->dbh;

    my $sth = $dbh->prepare(
          "SELECT blocked, COUNT(bug_status) " .
            "FROM bugs, dependencies " .
           "WHERE " . $dbh->sql_in('blocked', \@bug_list) .
             "AND bug_id = dependson " .
             "AND bug_status IN (" . join(', ', map {$dbh->quote($_)} BUG_STATE_OPEN)  . ") " .
          $dbh->sql_group_by('blocked'));
    $sth->execute();

    while (my ($bug_id, $dependencies) = $sth->fetchrow_array()) {
        push(@dependencies, { bug_id       => $bug_id,
                              dependencies => $dependencies });
    }

    return @dependencies;
}

# If a bug is moved to a product which allows less votes per bug
# compared to the previous product, extra votes need to be removed.
sub RemoveVotes {
    my ($id, $who, $reason) = (@_);
    my $dbh = Bugzilla->dbh;

    my $whopart = ($who) ? " AND votes.who = $who" : "";

    my $sth = $dbh->prepare("SELECT profiles.login_name, " .
                            "profiles.userid, votes.vote_count, " .
                            "products.votesperuser, products.maxvotesperbug " .
                            "FROM profiles " . 
                            "LEFT JOIN votes ON profiles.userid = votes.who " .
                            "LEFT JOIN bugs ON votes.bug_id = bugs.bug_id " .
                            "LEFT JOIN products ON products.id = bugs.product_id " .
                            "WHERE votes.bug_id = ? " . $whopart);
    $sth->execute($id);
    my @list;
    while (my ($name, $userid, $oldvotes, $votesperuser, $maxvotesperbug) = $sth->fetchrow_array()) {
        push(@list, [$name, $userid, $oldvotes, $votesperuser, $maxvotesperbug]);
    }

    # @messages stores all emails which have to be sent, if any.
    # This array is passed to the caller which will send these emails itself.
    my @messages = ();

    if (scalar(@list)) {
        foreach my $ref (@list) {
            my ($name, $userid, $oldvotes, $votesperuser, $maxvotesperbug) = (@$ref);

            $maxvotesperbug = min($votesperuser, $maxvotesperbug);

            # If this product allows voting and the user's votes are in
            # the acceptable range, then don't do anything.
            next if $votesperuser && $oldvotes <= $maxvotesperbug;

            # If the user has more votes on this bug than this product
            # allows, then reduce the number of votes so it fits
            my $newvotes = $maxvotesperbug;

            my $removedvotes = $oldvotes - $newvotes;

            if ($newvotes) {
                $dbh->do("UPDATE votes SET vote_count = ? " .
                         "WHERE bug_id = ? AND who = ?",
                         undef, ($newvotes, $id, $userid));
            } else {
                $dbh->do("DELETE FROM votes WHERE bug_id = ? AND who = ?",
                         undef, ($id, $userid));
            }

            # Notice that we did not make sure that the user fit within the $votesperuser
            # range.  This is considered to be an acceptable alternative to losing votes
            # during product moves.  Then next time the user attempts to change their votes,
            # they will be forced to fit within the $votesperuser limit.

            # Now lets send the e-mail to alert the user to the fact that their votes have
            # been reduced or removed.
            my $vars = {
                'to' => $name . Bugzilla->params->{'emailsuffix'},
                'bugid' => $id,
                'reason' => $reason,

                'votesremoved' => $removedvotes,
                'votesold' => $oldvotes,
                'votesnew' => $newvotes,
            };

            my $voter = new Bugzilla::User($userid);
            my $template = Bugzilla->template_inner($voter->settings->{'lang'}->{'value'});

            my $msg;
            $template->process("email/votes-removed.txt.tmpl", $vars, \$msg);
            push(@messages, $msg);
        }
        Bugzilla->template_inner("");

        my $votes = $dbh->selectrow_array("SELECT SUM(vote_count) " .
                                          "FROM votes WHERE bug_id = ?",
                                          undef, $id) || 0;
        $dbh->do("UPDATE bugs SET votes = ? WHERE bug_id = ?",
                 undef, ($votes, $id));
    }
    # Now return the array containing emails to be sent.
    return @messages;
}

# If a user votes for a bug, or the number of votes required to
# confirm a bug has been reduced, check if the bug is now confirmed.
sub CheckIfVotedConfirmed {
    my $id = shift;
    my $bug = new Bugzilla::Bug($id);

    my $ret = 0;
    if (!$bug->everconfirmed
        and $bug->product_obj->votes_to_confirm
        and $bug->votes >= $bug->product_obj->votes_to_confirm) 
    {
        $bug->add_comment('', { type => CMT_POPULAR_VOTES });

        if ($bug->bug_status eq 'UNCONFIRMED') {
            # Get a valid open state.
            my $new_status;
            foreach my $state (@{$bug->status->can_change_to}) {
                if ($state->is_open && $state->name ne 'UNCONFIRMED') {
                    $new_status = $state->name;
                    last;
                }
            }
            ThrowCodeError('no_open_bug_status') unless $new_status;

            # We cannot call $bug->set_status() here, because a user without
            # canconfirm privs should still be able to confirm a bug by
            # popular vote. We already know the new status is valid, so it's safe.
            $bug->{bug_status} = $new_status;
            $bug->{everconfirmed} = 1;
            delete $bug->{'status'}; # Contains the status object.
        }
        else {
            # If the bug is in a closed state, only set everconfirmed to 1.
            # Do not call $bug->_set_everconfirmed(), for the same reason as above.
            $bug->{everconfirmed} = 1;
        }
        $bug->update();

        $ret = 1;
    }
    return $ret;
}

################################################################################
# check_can_change_field() defines what users are allowed to change. You
# can add code here for site-specific policy changes, according to the
# instructions given in the Bugzilla Guide and below. Note that you may also
# have to update the Bugzilla::Bug::user() function to give people access to the
# options that they are permitted to change.
#
# check_can_change_field() returns true if the user is allowed to change this
# field, and false if they are not.
#
# The parameters to this method are as follows:
# $field    - name of the field in the bugs table the user is trying to change
# $oldvalue - what they are changing it from
# $newvalue - what they are changing it to
# $PrivilegesRequired - return the reason of the failure, if any
################################################################################
sub check_can_change_field {
    my $self = shift;
    my ($field, $oldvalue, $newvalue, $PrivilegesRequired) = (@_);
    my $user = Bugzilla->user;

    $oldvalue = defined($oldvalue) ? $oldvalue : '';
    $newvalue = defined($newvalue) ? $newvalue : '';

    # Return true if they haven't changed this field at all.
    if ($oldvalue eq $newvalue) {
        return 1;
    } elsif (ref($newvalue) eq 'ARRAY' && ref($oldvalue) eq 'ARRAY') {
        my ($removed, $added) = diff_arrays($oldvalue, $newvalue);
        return 1 if !scalar(@$removed) && !scalar(@$added);
    } elsif (trim($oldvalue) eq trim($newvalue)) {
        return 1;
    # numeric fields need to be compared using ==
    } elsif (($field eq 'estimated_time' || $field eq 'remaining_time')
             && $oldvalue == $newvalue)
    {
        return 1;
    }

    # Allow anyone to change comments.
    if ($field =~ /^longdesc/) {
        return 1;
    }

    # If the user isn't allowed to change a field, we must tell him who can.
    # We store the required permission set into the $PrivilegesRequired
    # variable which gets passed to the error template.
    #
    # $PrivilegesRequired = 0 : no privileges required;
    # $PrivilegesRequired = 1 : the reporter, assignee or an empowered user;
    # $PrivilegesRequired = 2 : the assignee or an empowered user;
    # $PrivilegesRequired = 3 : an empowered user.
    
    # Only users in the time-tracking group can change time-tracking fields.
    if ( grep($_ eq $field, qw(deadline estimated_time remaining_time)) ) {
        if (!$user->is_timetracker) {
            $$PrivilegesRequired = 3;
            return 0;
        }
    }

    # Allow anyone with (product-specific) "editbugs" privs to change anything.
    if ($user->in_group('editbugs', $self->{'product_id'})) {
        return 1;
    }

    # *Only* users with (product-specific) "canconfirm" privs can confirm bugs.
    if ($self->_changes_everconfirmed($field, $oldvalue, $newvalue)) {
        $$PrivilegesRequired = 3;
        return $user->in_group('canconfirm', $self->{'product_id'});
    }

    # Make sure that a valid bug ID has been given.
    if (!$self->{'error'}) {
        # Allow the assignee to change anything else.
        if ($self->{'assigned_to'} == $user->id
            || $self->{'_old_assigned_to'} && $self->{'_old_assigned_to'} == $user->id)
        {
            return 1;
        }

        # Allow the QA contact to change anything else.
        if (Bugzilla->params->{'useqacontact'}
            && (($self->{'qa_contact'} && $self->{'qa_contact'} == $user->id)
                || ($self->{'_old_qa_contact'} && $self->{'_old_qa_contact'} == $user->id)))
        {
            return 1;
        }
    }

    # At this point, the user is either the reporter or an
    # unprivileged user. We first check for fields the reporter
    # is not allowed to change.

    # The reporter may not:
    # - reassign bugs, unless the bugs are assigned to him;
    #   in that case we will have already returned 1 above
    #   when checking for the assignee of the bug.
    if ($field eq 'assigned_to') {
        $$PrivilegesRequired = 2;
        return 0;
    }
    # - change the QA contact
    if ($field eq 'qa_contact') {
        $$PrivilegesRequired = 2;
        return 0;
    }
    # - change the target milestone
    if ($field eq 'target_milestone') {
        $$PrivilegesRequired = 2;
        return 0;
    }
    # - change the priority (unless he could have set it originally)
    if ($field eq 'priority'
        && !Bugzilla->params->{'letsubmitterchoosepriority'})
    {
        $$PrivilegesRequired = 2;
        return 0;
    }
    # - unconfirm bugs (confirming them is handled above)
    if ($field eq 'everconfirmed') {
        $$PrivilegesRequired = 2;
        return 0;
    }
    # - change the status from one open state to another
    if ($field eq 'bug_status'
        && is_open_state($oldvalue) && is_open_state($newvalue)) 
    {
       $$PrivilegesRequired = 2;
       return 0;
    }

    # The reporter is allowed to change anything else.
    if (!$self->{'error'} && $self->{'reporter_id'} == $user->id) {
        return 1;
    }

    # If we haven't returned by this point, then the user doesn't
    # have the necessary permissions to change this field.
    $$PrivilegesRequired = 1;
    return 0;
}

# A helper for check_can_change_field
sub _changes_everconfirmed {
    my ($self, $field, $old, $new) = @_;
    return 1 if $field eq 'everconfirmed';
    if ($field eq 'bug_status') {
        if ($self->everconfirmed) {
            # Moving a confirmed bug to UNCONFIRMED will change everconfirmed.
            return 1 if $new eq 'UNCONFIRMED';
        }
        else {
            # Moving an unconfirmed bug to an open state that isn't 
            # UNCONFIRMED will confirm the bug.
            return 1 if (is_open_state($new) and $new ne 'UNCONFIRMED');
        }
    }
    return 0;
}

#
# Field Validation
#

# Validate and return a hash of dependencies
sub ValidateDependencies {
    my $fields = {};
    # These can be arrayrefs or they can be strings.
    $fields->{'dependson'} = shift;
    $fields->{'blocked'} = shift;
    my $id = shift || 0;

    unless (defined($fields->{'dependson'})
            || defined($fields->{'blocked'}))
    {
        return;
    }

    my $dbh = Bugzilla->dbh;
    my %deps;
    my %deptree;
    foreach my $pair (["blocked", "dependson"], ["dependson", "blocked"]) {
        my ($me, $target) = @{$pair};
        $deptree{$target} = [];
        $deps{$target} = [];
        next unless $fields->{$target};

        my %seen;
        my $target_array = ref($fields->{$target}) ? $fields->{$target}
                           : [split(/[\s,]+/, $fields->{$target})];
        foreach my $i (@$target_array) {
            if ($id == $i) {
                ThrowUserError("dependency_loop_single");
            }
            if (!exists $seen{$i}) {
                push(@{$deptree{$target}}, $i);
                $seen{$i} = 1;
            }
        }
        # populate $deps{$target} as first-level deps only.
        # and find remainder of dependency tree in $deptree{$target}
        @{$deps{$target}} = @{$deptree{$target}};
        my @stack = @{$deps{$target}};
        while (@stack) {
            my $i = shift @stack;
            my $dep_list =
                $dbh->selectcol_arrayref("SELECT $target
                                          FROM dependencies
                                          WHERE $me = ?", undef, $i);
            foreach my $t (@$dep_list) {
                # ignore any _current_ dependencies involving this bug,
                # as they will be overwritten with data from the form.
                if ($t != $id && !exists $seen{$t}) {
                    push(@{$deptree{$target}}, $t);
                    push @stack, $t;
                    $seen{$t} = 1;
                }
            }
        }
    }

    my @deps   = @{$deptree{'dependson'}};
    my @blocks = @{$deptree{'blocked'}};
    my %union = ();
    my %isect = ();
    foreach my $b (@deps, @blocks) { $union{$b}++ && $isect{$b}++ }
    my @isect = keys %isect;
    if (scalar(@isect) > 0) {
        ThrowUserError("dependency_loop_multi", {'deps' => \@isect});
    }
    return %deps;
}


#####################################################################
# Autoloaded Accessors
#####################################################################

# Determines whether an attribute access trapped by the AUTOLOAD function
# is for a valid bug attribute.  Bug attributes are properties and methods
# predefined by this module as well as bug fields for which an accessor
# can be defined by AUTOLOAD at runtime when the accessor is first accessed.
#
# XXX Strangely, some predefined attributes are on the list, but others aren't,
# and the original code didn't specify why that is.  Presumably the only
# attributes that need to be on this list are those that aren't predefined;
# we should verify that and update the list accordingly.
#
sub _validate_attribute {
    my ($attribute) = @_;

    my @valid_attributes = (
        # Miscellaneous properties and methods.
        qw(error groups product_id component_id
           comments milestoneurl attachments isopened
           flag_types num_attachment_flag_types
           show_attachment_flags any_flags_requesteeble),

        # Bug fields.
        Bugzilla::Bug->fields
    );

    return grep($attribute eq $_, @valid_attributes) ? 1 : 0;
}

sub AUTOLOAD {
  use vars qw($AUTOLOAD);
  my $attr = $AUTOLOAD;

  $attr =~ s/.*:://;
  return unless $attr=~ /[^A-Z]/;
  if (!_validate_attribute($attr)) {
      require Carp;
      Carp::confess("invalid bug attribute $attr");
  }

  no strict 'refs';
  *$AUTOLOAD = sub {
      my $self = shift;

      return $self->{$attr} if defined $self->{$attr};

      $self->{_multi_selects} ||= [Bugzilla->get_fields(
          {custom => 1, type => FIELD_TYPE_MULTI_SELECT })];
      if ( grep($_->name eq $attr, @{$self->{_multi_selects}}) ) {
          # There is a bug in Perl 5.10.0, which is fixed in 5.10.1,
          # which taints $attr at this point. trick_taint() can go
          # away once we require 5.10.1 or newer.
          trick_taint($attr);

          $self->{$attr} ||= Bugzilla->dbh->selectcol_arrayref(
              "SELECT value FROM bug_$attr WHERE bug_id = ? ORDER BY value",
              undef, $self->id);
          return $self->{$attr};
      }

      return '';
  };

  goto &$AUTOLOAD;
}

1;
