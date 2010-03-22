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
# Contributor(s): Terry Weissman <terry@mozilla.org>
#                 Dan Mosedale <dmose@mozilla.org>
#                 Jacob Steenhagen <jake@bugzilla.org>
#                 Bradley Baetz <bbaetz@student.usyd.edu.au>
#                 Christopher Aillon <christopher@aillon.com>
#                 Tobias Burnus <burnus@net-b.de>
#                 Myk Melez <myk@mozilla.org>
#                 Max Kanat-Alexander <mkanat@bugzilla.org>
#                 Frédéric Buclin <LpSolit@gmail.com>
#                 Greg Hendricks <ghendricks@novell.com>
#                 David D. Kilzer <ddkilzer@kilzer.net>


package Bugzilla::Template;

use strict;

use Bugzilla::Bug;
use Bugzilla::Constants;
use Bugzilla::Hook;
use Bugzilla::Install::Requirements;
use Bugzilla::Install::Util qw(install_string template_include_path 
                               include_languages);
use Bugzilla::Keyword;
use Bugzilla::Util;
use Bugzilla::User;
use Bugzilla::Error;
use Bugzilla::Status;
use Bugzilla::Token;

use Cwd qw(abs_path);
use MIME::Base64;
use Date::Format ();
use File::Basename qw(basename dirname);
use File::Find;
use File::Path qw(rmtree mkpath);
use File::Spec;
use IO::Dir;
use Scalar::Util qw(blessed);

use base qw(Template);

# Convert the constants in the Bugzilla::Constants module into a hash we can
# pass to the template object for reflection into its "constants" namespace
# (which is like its "variables" namespace, but for constants).  To do so, we
# traverse the arrays of exported and exportable symbols and ignoring the rest
# (which, if Constants.pm exports only constants, as it should, will be nothing else).
sub _load_constants {
    my %constants;
    foreach my $constant (@Bugzilla::Constants::EXPORT,
                          @Bugzilla::Constants::EXPORT_OK)
    {
        if (ref Bugzilla::Constants->$constant) {
            $constants{$constant} = Bugzilla::Constants->$constant;
        }
        else {
            my @list = (Bugzilla::Constants->$constant);
            $constants{$constant} = (scalar(@list) == 1) ? $list[0] : \@list;
        }
    }
    return \%constants;
}

# Returns the path to the templates based on the Accept-Language
# settings of the user and of the available languages
# If no Accept-Language is present it uses the defined default
# Templates may also be found in the extensions/ tree
sub getTemplateIncludePath {
    my $cache = Bugzilla->request_cache;
    my $lang  = $cache->{'language'} || '';
    $cache->{"template_include_path_$lang"} ||= template_include_path({
        use_languages => Bugzilla->languages,
        only_language => $lang });
    return $cache->{"template_include_path_$lang"};
}

sub get_format {
    my $self = shift;
    my ($template, $format, $ctype) = @_;

    $ctype ||= 'html';
    $format ||= '';

    # Security - allow letters and a hyphen only
    $ctype =~ s/[^a-zA-Z\-]//g;
    $format =~ s/[^a-zA-Z\-]//g;
    trick_taint($ctype);
    trick_taint($format);

    $template .= ($format ? "-$format" : "");
    $template .= ".$ctype.tmpl";

    # Now check that the template actually exists. We only want to check
    # if the template exists; any other errors (eg parse errors) will
    # end up being detected later.
    eval {
        $self->context->template($template);
    };
    # This parsing may seem fragile, but it's OK:
    # http://lists.template-toolkit.org/pipermail/templates/2003-March/004370.html
    # Even if it is wrong, any sort of error is going to cause a failure
    # eventually, so the only issue would be an incorrect error message
    if ($@ && $@->info =~ /: not found$/) {
        ThrowUserError('format_not_found', {'format' => $format,
                                            'ctype'  => $ctype});
    }

    # Else, just return the info
    return
    {
        'template'    => $template,
        'extension'   => $ctype,
        'ctype'       => Bugzilla::Constants::contenttypes->{$ctype}
    };
}

# This routine quoteUrls contains inspirations from the HTML::FromText CPAN
# module by Gareth Rees <garethr@cre.canon.co.uk>.  It has been heavily hacked,
# all that is really recognizable from the original is bits of the regular
# expressions.
# This has been rewritten to be faster, mainly by substituting 'as we go'.
# If you want to modify this routine, read the comments carefully

sub quoteUrls {
    my ($text, $bug, $comment) = (@_);
    return $text unless $text;

    # We use /g for speed, but uris can have other things inside them
    # (http://foo/bug#3 for example). Filtering that out filters valid
    # bug refs out, so we have to do replacements.
    # mailto can't contain space or #, so we don't have to bother for that
    # Do this by escaping \0 to \1\0, and replacing matches with \0\0$count\0\0
    # \0 is used because it's unlikely to occur in the text, so the cost of
    # doing this should be very small

    # escape the 2nd escape char we're using
    my $chr1 = chr(1);
    $text =~ s/\0/$chr1\0/g;

    # However, note that adding the title (for buglinks) can affect things
    # In particular, attachment matches go before bug titles, so that titles
    # with 'attachment 1' don't double match.
    # Dupe checks go afterwards, because that uses ^ and \Z, which won't occur
    # if it was substituted as a bug title (since that always involve leading
    # and trailing text)

    # Because of entities, it's easier (and quicker) to do this before escaping

    my @things;
    my $count = 0;
    my $tmp;

    my @hook_regexes;
    Bugzilla::Hook::process('bug_format_comment',
        { text => \$text, bug => $bug, regexes => \@hook_regexes,
          comment => $comment });

    foreach my $re (@hook_regexes) {
        my ($match, $replace) = @$re{qw(match replace)};
        if (ref($replace) eq 'CODE') {
            $text =~ s/$match/($things[$count++] = $replace->({matches => [
                                                               $1, $2, $3, $4,
                                                               $5, $6, $7, $8, 
                                                               $9, $10]}))
                               && ("\0\0" . ($count-1) . "\0\0")/egx;
        }
        else {
            $text =~ s/$match/($things[$count++] = $replace) 
                              && ("\0\0" . ($count-1) . "\0\0")/egx;
        }
    }

    # Provide tooltips for full bug links (Bug 74355)
    my $urlbase_re = '(' . join('|',
        map { qr/$_/ } grep($_, Bugzilla->params->{'urlbase'}, 
                            Bugzilla->params->{'sslbase'})) . ')';
    $text =~ s~\b(${urlbase_re}\Qshow_bug.cgi?id=\E([0-9]+)(\#c([0-9]+))?)\b
              ~($things[$count++] = get_bug_link($3, $1, { comment_num => $5 })) &&
               ("\0\0" . ($count-1) . "\0\0")
              ~egox;

    # non-mailto protocols
    my $safe_protocols = join('|', SAFE_PROTOCOLS);
    my $protocol_re = qr/($safe_protocols)/i;

    $text =~ s~\b(${protocol_re}:  # The protocol:
                  [^\s<>\"]+       # Any non-whitespace
                  [\w\/])          # so that we end in \w or /
              ~($tmp = html_quote($1)) &&
               ($things[$count++] = "<a href=\"$tmp\">$tmp</a>") &&
               ("\0\0" . ($count-1) . "\0\0")
              ~egox;

    # We have to quote now, otherwise the html itself is escaped
    # THIS MEANS THAT A LITERAL ", <, >, ' MUST BE ESCAPED FOR A MATCH

    $text = html_quote($text);

    # Color quoted text
    $text =~ s~^(&gt;.+)$~<span class="quote">$1</span >~mg;
    $text =~ s~</span >\n<span class="quote">~\n~g;

    # mailto:
    # Use |<nothing> so that $1 is defined regardless
    $text =~ s~\b(mailto:|)?([\w\.\-\+\=]+\@[\w\-]+(?:\.[\w\-]+)+)\b
              ~<a href=\"mailto:$2\">$1$2</a>~igx;

    # attachment links
    $text =~ s~\b(attachment\s*\#?\s*(\d+))
              ~($things[$count++] = get_attachment_link($2, $1)) &&
               ("\0\0" . ($count-1) . "\0\0")
              ~egmxi;

    # Current bug ID this comment belongs to
    my $current_bugurl = $bug ? ("show_bug.cgi?id=" . $bug->id) : "";

    # This handles bug a, comment b type stuff. Because we're using /g
    # we have to do this in one pattern, and so this is semi-messy.
    # Also, we can't use $bug_re?$comment_re? because that will match the
    # empty string
    my $bug_word = get_text('term', { term => 'bug' });
    my $bug_re = qr/\Q$bug_word\E\s*\#?\s*(\d+)/i;
    my $comment_re = qr/comment\s*\#?\s*(\d+)/i;
    $text =~ s~\b($bug_re(?:\s*,?\s*$comment_re)?|$comment_re)
              ~ # We have several choices. $1 here is the link, and $2-4 are set
                # depending on which part matched
               (defined($2) ? get_bug_link($2, $1, { comment_num => $3 }) :
                              "<a href=\"$current_bugurl#c$4\">$1</a>")
              ~egox;

    # Old duplicate markers. These don't use $bug_word because they are old
    # and were never customizable.
    $text =~ s~(?<=^\*\*\*\ This\ bug\ has\ been\ marked\ as\ a\ duplicate\ of\ )
               (\d+)
               (?=\ \*\*\*\Z)
              ~get_bug_link($1, $1)
              ~egmx;

    # Now remove the encoding hacks
    $text =~ s/\0\0(\d+)\0\0/$things[$1]/eg;
    $text =~ s/$chr1\0/\0/g;

    return $text;
}

# Creates a link to an attachment, including its title.
sub get_attachment_link {
    my ($attachid, $link_text) = @_;
    my $dbh = Bugzilla->dbh;

    detaint_natural($attachid)
      || die "get_attachment_link() called with non-integer attachment number";

    my ($bugid, $isobsolete, $desc, $is_patch) =
        $dbh->selectrow_array('SELECT bug_id, isobsolete, description, ispatch
                               FROM attachments WHERE attach_id = ?',
                               undef, $attachid);

    if ($bugid) {
        my $title = "";
        my $className = "";
        if (Bugzilla->user->can_see_bug($bugid)) {
            $title = $desc;
        }
        if ($isobsolete) {
            $className = "bz_obsolete";
        }
        # Prevent code injection in the title.
        $title = html_quote(clean_text($title));

        $link_text =~ s/ \[details\]$//;
        my $linkval = "attachment.cgi?id=$attachid";

        # If the attachment is a patch, try to link to the diff rather
        # than the text, by default.
        my $patchlink = "";
        if ($is_patch and Bugzilla->feature('patch_viewer')) {
            $patchlink = '&amp;action=diff';
        }

        # Whitespace matters here because these links are in <pre> tags.
        return qq|<span class="$className">|
               . qq|<a href="${linkval}${patchlink}" name="attach_${attachid}" title="$title">$link_text</a>|
               . qq| <a href="${linkval}&amp;action=edit" title="$title">[details]</a>|
               . qq|</span>|;
    }
    else {
        return qq{$link_text};
    }
}

# Creates a link to a bug, including its title.
# It takes either two or three parameters:
#  - The bug number
#  - The link text, to place between the <a>..</a>
#  - An optional comment number, for linking to a particular
#    comment in the bug

sub get_bug_link {
    my ($bug, $link_text, $options) = @_;
    my $dbh = Bugzilla->dbh;

    if (!$bug) {
        return html_quote('<missing bug number>');
    }

    $bug = blessed($bug) ? $bug : new Bugzilla::Bug($bug);
    return $link_text if $bug->{error};
    
    # Initialize these variables to be "" so that we don't get warnings
    # if we don't change them below (which is highly likely).
    my ($pre, $title, $post) = ("", "", "");

    $title = get_text('get_status', { status => $bug->bug_status });
    if ($bug->bug_status eq 'UNCONFIRMED') {
        $pre = "<i>";
        $post = "</i>";
    }
    if ($bug->resolution) {
        $pre .= '<span class="bz_closed">';
        $title .= ' ' . get_text('get_resolution',
                                 { resolution => $bug->resolution });
        $post .= '</span>';
    }
    if (Bugzilla->user->can_see_bug($bug)) {
        $title .= " - " . $bug->short_desc;
        if ($options->{use_alias} && $link_text =~ /^\d+$/ && $bug->alias) {
            $link_text = $bug->alias;
        }
    }
    # Prevent code injection in the title.
    $title = html_quote(clean_text($title));

    my $linkval = "show_bug.cgi?id=" . $bug->id;
    if ($options->{comment_num}) {
        $linkval .= "#c" . $options->{comment_num};
    }
    return qq{$pre<a href="$linkval" title="$title">$link_text</a>$post};
}

###############################################################################
# Templatization Code

# The Template Toolkit throws an error if a loop iterates >1000 times.
# We want to raise that limit.
# NOTE: If you change this number, you MUST RE-RUN checksetup.pl!!!
# If you do not re-run checksetup.pl, the change you make will not apply
$Template::Directive::WHILE_MAX = 1000000;

# Use the Toolkit Template's Stash module to add utility pseudo-methods
# to template variables.
use Template::Stash;

# Add "contains***" methods to list variables that search for one or more 
# items in a list and return boolean values representing whether or not 
# one/all/any item(s) were found.
$Template::Stash::LIST_OPS->{ contains } =
  sub {
      my ($list, $item) = @_;
      return grep($_ eq $item, @$list);
  };

$Template::Stash::LIST_OPS->{ containsany } =
  sub {
      my ($list, $items) = @_;
      foreach my $item (@$items) { 
          return 1 if grep($_ eq $item, @$list);
      }
      return 0;
  };

# Clone the array reference to leave the original one unaltered.
$Template::Stash::LIST_OPS->{ clone } =
  sub {
      my $list = shift;
      return [@$list];
  };

# Allow us to still get the scalar if we use the list operation ".0" on it,
# as we often do for defaults in query.cgi and other places.
$Template::Stash::SCALAR_OPS->{ 0 } = 
  sub {
      return $_[0];
  };

# Add a "substr" method to the Template Toolkit's "scalar" object
# that returns a substring of a string.
$Template::Stash::SCALAR_OPS->{ substr } = 
  sub {
      my ($scalar, $offset, $length) = @_;
      return substr($scalar, $offset, $length);
  };

# Add a "truncate" method to the Template Toolkit's "scalar" object
# that truncates a string to a certain length.
$Template::Stash::SCALAR_OPS->{ truncate } = 
  sub {
      my ($string, $length, $ellipsis) = @_;
      $ellipsis ||= "";
      
      return $string if !$length || length($string) <= $length;
      
      my $strlen = $length - length($ellipsis);
      my $newstr = substr($string, 0, $strlen) . $ellipsis;
      return $newstr;
  };

# Create the template object that processes templates and specify
# configuration parameters that apply to all templates.

###############################################################################

# Construct the Template object

# Note that all of the failure cases here can't use templateable errors,
# since we won't have a template to use...

sub create {
    my $class = shift;
    my %opts = @_;

    # IMPORTANT - If you make any FILTER changes here, make sure to
    # make them in t/004.template.t also, if required.

    my $config = {
        # Colon-separated list of directories containing templates.
        INCLUDE_PATH => $opts{'include_path'} || getTemplateIncludePath(),

        # Remove white-space before template directives (PRE_CHOMP) and at the
        # beginning and end of templates and template blocks (TRIM) for better
        # looking, more compact content.  Use the plus sign at the beginning
        # of directives to maintain white space (i.e. [%+ DIRECTIVE %]).
        PRE_CHOMP => 1,
        TRIM => 1,

        # Bugzilla::Template::Plugin::Hook uses the absolute (in mod_perl)
        # or relative (in mod_cgi) paths of hook files to explicitly compile
        # a specific file. Also, these paths may be absolute at any time
        # if a packager has modified bz_locations() to contain absolute
        # paths.
        ABSOLUTE => 1,
        RELATIVE => $ENV{MOD_PERL} ? 0 : 1,

        COMPILE_DIR => bz_locations()->{'datadir'} . "/template",

        # Initialize templates (f.e. by loading plugins like Hook).
        PRE_PROCESS => ["global/initialize.none.tmpl"],

        ENCODING => Bugzilla->params->{'utf8'} ? 'UTF-8' : undef,

        # Functions for processing text within templates in various ways.
        # IMPORTANT!  When adding a filter here that does not override a
        # built-in filter, please also add a stub filter to t/004template.t.
        FILTERS => {

            # Render text in required style.

            inactive => [
                sub {
                    my($context, $isinactive) = @_;
                    return sub {
                        return $isinactive ? '<span class="bz_inactive">'.$_[0].'</span>' : $_[0];
                    }
                }, 1
            ],

            closed => [
                sub {
                    my($context, $isclosed) = @_;
                    return sub {
                        return $isclosed ? '<span class="bz_closed">'.$_[0].'</span>' : $_[0];
                    }
                }, 1
            ],

            obsolete => [
                sub {
                    my($context, $isobsolete) = @_;
                    return sub {
                        return $isobsolete ? '<span class="bz_obsolete">'.$_[0].'</span>' : $_[0];
                    }
                }, 1
            ],

            # Returns the text with backslashes, single/double quotes,
            # and newlines/carriage returns escaped for use in JS strings.
            js => sub {
                my ($var) = @_;
                $var =~ s/([\\\'\"\/])/\\$1/g;
                $var =~ s/\n/\\n/g;
                $var =~ s/\r/\\r/g;
                $var =~ s/\@/\\x40/g; # anti-spam for email addresses
                $var =~ s/</\\x3c/g;
                return $var;
            },
            
            # Converts data to base64
            base64 => sub {
                my ($data) = @_;
                return encode_base64($data);
            },
            
            # HTML collapses newlines in element attributes to a single space,
            # so form elements which may have whitespace (ie comments) need
            # to be encoded using &#013;
            # See bugs 4928, 22983 and 32000 for more details
            html_linebreak => sub {
                my ($var) = @_;
                $var =~ s/\r\n/\&#013;/g;
                $var =~ s/\n\r/\&#013;/g;
                $var =~ s/\r/\&#013;/g;
                $var =~ s/\n/\&#013;/g;
                return $var;
            },

            # Prevents line break on hyphens and whitespaces.
            no_break => sub {
                my ($var) = @_;
                $var =~ s/ /\&nbsp;/g;
                $var =~ s/-/\&#8209;/g;
                return $var;
            },

            xml => \&Bugzilla::Util::xml_quote ,

            # This filter escapes characters in a variable or value string for
            # use in a query string.  It escapes all characters NOT in the
            # regex set: [a-zA-Z0-9_\-.].  The 'uri' filter should be used for
            # a full URL that may have characters that need encoding.
            url_quote => \&Bugzilla::Util::url_quote ,

            # This filter is similar to url_quote but used a \ instead of a %
            # as prefix. In addition it replaces a ' ' by a '_'.
            css_class_quote => \&Bugzilla::Util::css_class_quote ,

            quoteUrls => [ sub {
                               my ($context, $bug, $comment) = @_;
                               return sub {
                                   my $text = shift;
                                   return quoteUrls($text, $bug, $comment);
                               };
                           },
                           1
                         ],

            bug_link => [ sub {
                              my ($context, $bug, $options) = @_;
                              return sub {
                                  my $text = shift;
                                  return get_bug_link($bug, $text, $options);
                              };
                          },
                          1
                        ],

            bug_list_link => sub
            {
                my $buglist = shift;
                return join(", ", map(get_bug_link($_, $_), split(/ *, */, $buglist)));
            },

            # In CSV, quotes are doubled, and any value containing a quote or a
            # comma is enclosed in quotes.
            csv => sub
            {
                my ($var) = @_;
                $var =~ s/\"/\"\"/g;
                if ($var !~ /^-?(\d+\.)?\d*$/) {
                    $var = "\"$var\"";
                }
                return $var;
            } ,

            # Format a filesize in bytes to a human readable value
            unitconvert => sub
            {
                my ($data) = @_;
                my $retval = "";
                my %units = (
                    'KB' => 1024,
                    'MB' => 1024 * 1024,
                    'GB' => 1024 * 1024 * 1024,
                );

                if ($data < 1024) {
                    return "$data bytes";
                } 
                else {
                    my $u;
                    foreach $u ('GB', 'MB', 'KB') {
                        if ($data >= $units{$u}) {
                            return sprintf("%.2f %s", $data/$units{$u}, $u);
                        }
                    }
                }
            },

            # Format a time for display (more info in Bugzilla::Util)
            time => [ sub {
                          my ($context, $format, $timezone) = @_;
                          return sub {
                              my $time = shift;
                              return format_time($time, $format, $timezone);
                          };
                      },
                      1
                    ],

            html => \&Bugzilla::Util::html_quote,

            html_light => \&Bugzilla::Util::html_light_quote,

            email => \&Bugzilla::Util::email_filter,

            # iCalendar contentline filter
            ics => [ sub {
                         my ($context, @args) = @_;
                         return sub {
                             my ($var) = shift;
                             my ($par) = shift @args;
                             my ($output) = "";

                             $var =~ s/[\r\n]/ /g;
                             $var =~ s/([;\\\",])/\\$1/g;

                             if ($par) {
                                 $output = sprintf("%s:%s", $par, $var);
                             } else {
                                 $output = $var;
                             }
                             
                             $output =~ s/(.{75,75})/$1\n /g;

                             return $output;
                         };
                     },
                     1
                     ],

            # Note that using this filter is even more dangerous than
            # using "none," and you should only use it when you're SURE
            # the output won't be displayed directly to a web browser.
            txt => sub {
                my ($var) = @_;
                # Trivial HTML tag remover
                $var =~ s/<[^>]*>//g;
                # And this basically reverses the html filter.
                $var =~ s/\&#64;/@/g;
                $var =~ s/\&lt;/</g;
                $var =~ s/\&gt;/>/g;
                $var =~ s/\&quot;/\"/g;
                $var =~ s/\&amp;/\&/g;
                # Now remove extra whitespace, and wrap it to 72 characters.
                my $collapse_filter = $Template::Filters::FILTERS->{collapse};
                $var = $collapse_filter->($var);
                $var = wrap_comment($var, 72);
                return $var;
            },

            # Wrap a displayed comment to the appropriate length
            wrap_comment => [
                sub {
                    my ($context, $cols) = @_;
                    return sub { wrap_comment($_[0], $cols) }
                }, 1],

            # We force filtering of every variable in key security-critical
            # places; we have a none filter for people to use when they 
            # really, really don't want a variable to be changed.
            none => sub { return $_[0]; } ,
        },

        PLUGIN_BASE => 'Bugzilla::Template::Plugin',

        CONSTANTS => _load_constants(),

        # Default variables for all templates
        VARIABLES => {
            # Function for retrieving global parameters.
            'Param' => sub { return Bugzilla->params->{$_[0]}; },

            # Function to create date strings
            'time2str' => \&Date::Format::time2str,

            # Generic linear search function
            'lsearch' => \&Bugzilla::Util::lsearch,

            # Currently logged in user, if any
            # If an sudo session is in progress, this is the user we're faking
            'user' => sub { return Bugzilla->user; },
           
            # Currenly active language
            # XXX Eventually this should probably be replaced with something
            # like Bugzilla->language.
            'current_language' => sub {
                my ($language) = include_languages();
                return $language;
            },

            # If an sudo session is in progress, this is the user who
            # started the session.
            'sudoer' => sub { return Bugzilla->sudoer; },

            # SendBugMail - sends mail about a bug, using Bugzilla::BugMail.pm
            'SendBugMail' => sub {
                my ($id, $mailrecipients) = (@_);
                require Bugzilla::BugMail;
                Bugzilla::BugMail::Send($id, $mailrecipients);
            },

            # Allow templates to access the "corect" URLBase value
            'urlbase' => sub { return Bugzilla::Util::correct_urlbase(); },

            # Allow templates to access docs url with users' preferred language
            'docs_urlbase' => sub { 
                my ($language) = include_languages();
                my $docs_urlbase = Bugzilla->params->{'docs_urlbase'};
                $docs_urlbase =~ s/\%lang\%/$language/;
                return $docs_urlbase;
            },

            # Allow templates to generate a token themselves.
            'issue_hash_token' => \&Bugzilla::Token::issue_hash_token,

            # A way for all templates to get at Field data, cached.
            'bug_fields' => sub {
                my $cache = Bugzilla->request_cache;
                $cache->{template_bug_fields} ||= 
                    { map { $_->name => $_ } Bugzilla->get_fields() };
                return $cache->{template_bug_fields};
            },

            # Whether or not keywords are enabled, in this Bugzilla.
            'use_keywords' => sub { return Bugzilla::Keyword->any_exist; },

            'last_bug_list' => sub {
                my @bug_list;
                my $cgi = Bugzilla->cgi;
                if ($cgi->cookie("BUGLIST")) {
                    @bug_list = split(/:/, $cgi->cookie("BUGLIST"));
                }
                return \@bug_list;
            },

            'feature_enabled' => sub { return Bugzilla->feature(@_); },

            'install_string' => \&Bugzilla::Install::Util::install_string,

            # These don't work as normal constants.
            DB_MODULE        => \&Bugzilla::Constants::DB_MODULE,
            REQUIRED_MODULES => 
                \&Bugzilla::Install::Requirements::REQUIRED_MODULES,
            OPTIONAL_MODULES => sub {
                my @optional = @{OPTIONAL_MODULES()};
                foreach my $item (@optional) {
                    my @features;
                    foreach my $feat_id (@{ $item->{feature} }) {
                        push(@features, install_string("feature_$feat_id"));
                    }
                    $item->{feature} = \@features;
                }
                return \@optional;
            },
        },
    };

    local $Template::Config::CONTEXT = 'Bugzilla::Template::Context';

    Bugzilla::Hook::process('template_before_create', { config => $config });
    my $template = $class->new($config) 
        || die("Template creation failed: " . $class->error());
    return $template;
}

# Used as part of the two subroutines below.
our %_templates_to_precompile;
sub precompile_templates {
    my ($output) = @_;

    # Remove the compiled templates.
    my $datadir = bz_locations()->{'datadir'};
    if (-e "$datadir/template") {
        print install_string('template_removing_dir') . "\n" if $output;

        # This frequently fails if the webserver made the files, because
        # then the webserver owns the directories.
        rmtree("$datadir/template");

        # Check that the directory was really removed, and if not, move it
        # into data/deleteme/.
        if (-e "$datadir/template") {
            print STDERR "\n\n",
                install_string('template_removal_failed', 
                               { datadir => $datadir }), "\n\n";
            mkpath("$datadir/deleteme");
            my $random = generate_random_password();
            rename("$datadir/template", "$datadir/deleteme/$random")
              or die "move failed: $!";
        }
    }

    print install_string('template_precompile') if $output;

    my $paths = template_include_path({ use_languages => Bugzilla->languages });

    foreach my $dir (@$paths) {
        my $template = Bugzilla::Template->create(include_path => [$dir]);

        %_templates_to_precompile = ();
        # Traverse the template hierarchy.
        find({ wanted => \&_precompile_push, no_chdir => 1 }, $dir);
        # The sort isn't totally necessary, but it makes debugging easier
        # by making the templates always be compiled in the same order.
        foreach my $file (sort keys %_templates_to_precompile) {
            $file =~ s{^\Q$dir\E/}{};
            # Compile the template but throw away the result. This has the side-
            # effect of writing the compiled version to disk.
            $template->context->template($file);
        }
    }

    # Under mod_perl, we look for templates using the absolute path of the
    # template directory, which causes Template Toolkit to look for their 
    # *compiled* versions using the full absolute path under the data/template
    # directory. (Like data/template/var/www/html/bugzilla/.) To avoid
    # re-compiling templates under mod_perl, we symlink to the
    # already-compiled templates. This doesn't work on Windows.
    if (!ON_WINDOWS) {
        # We do these separately in case they're in different locations.
        _do_template_symlink(bz_locations()->{'templatedir'});
        _do_template_symlink(bz_locations()->{'extensionsdir'});
    }

    # If anything created a Template object before now, clear it out.
    delete Bugzilla->request_cache->{template};

    print install_string('done') . "\n" if $output;
}

# Helper for precompile_templates
sub _precompile_push {
    my $name = $File::Find::name;
    return if (-d $name);
    return if ($name =~ /\/CVS\//);
    return if ($name !~ /\.tmpl$/);
    $_templates_to_precompile{$name} = 1;
}

# Helper for precompile_templates
sub _do_template_symlink {
    my $dir_to_symlink = shift;

    my $abs_path = abs_path($dir_to_symlink);

    # If $dir_to_symlink is already an absolute path (as might happen
    # with packagers who set $libpath to an absolute path), then we don't
    # need to do this symlink.
    return if ($abs_path eq $dir_to_symlink);

    my $abs_root  = dirname($abs_path);
    my $dir_name  = basename($abs_path);
    my $datadir   = bz_locations()->{'datadir'};
    my $container = "$datadir/template$abs_root";
    mkpath($container);
    my $target = "$datadir/template/$dir_name";
    # Check if the directory exists, because if there are no extensions,
    # there won't be an "data/template/extensions" directory to link to.
    if (-d $target) {
        # We use abs2rel so that the symlink will look like 
        # "../../../../template" which works, while just 
        # "data/template/template/" doesn't work.
        my $relative_target = File::Spec->abs2rel($target, $container);

        my $link_name = "$container/$dir_name";
        symlink($relative_target, $link_name)
          or warn "Could not make $link_name a symlink to $relative_target: $!";
    }
}

1;

__END__

=head1 NAME

Bugzilla::Template - Wrapper around the Template Toolkit C<Template> object

=head1 SYNOPSIS

  my $template = Bugzilla::Template->create;
  my $format = $template->get_format("foo/bar",
                                     scalar($cgi->param('format')),
                                     scalar($cgi->param('ctype')));

=head1 DESCRIPTION

This is basically a wrapper so that the correct arguments get passed into
the C<Template> constructor.

It should not be used directly by scripts or modules - instead, use
C<Bugzilla-E<gt>instance-E<gt>template> to get an already created module.

=head1 SUBROUTINES

=over

=item C<precompile_templates($output)>

Description: Compiles all of Bugzilla's templates in every language.
             Used mostly by F<checksetup.pl>.

Params:      C<$output> - C<true> if you want the function to print
               out information about what it's doing.

Returns:     nothing

=back

=head1 METHODS

=over

=item C<get_format($file, $format, $ctype)>

 Description: Construct a format object from URL parameters.

 Params:      $file   - Name of the template to display.
              $format - When the template exists under several formats
                        (e.g. table or graph), specify the one to choose.
              $ctype  - Content type, see Bugzilla::Constants::contenttypes.

 Returns:     A format object.

=back

=head1 SEE ALSO

L<Bugzilla>, L<Template>
