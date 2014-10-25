#!/usr/bin/perl -w
package Mail::IMAPTalk;

=head1 NAME

Mail::IMAPTalk - IMAP client interface with lots of features

=head1 SYNOPSIS

  use Mail::IMAPTalk;

  $IMAP = Mail::IMAPTalk->new(
      Server   => $IMAPServer,
      Username => 'foo',
      Password => 'bar',
      Uid      => 1 )
    || die "Failed to connect/login to IMAP server";

  # Append message to folder
  open(my $F, 'rfc822msg.txt');
  $IMAP->append($FolderName, $F) || dir $@;
  close($F);

  # Select folder and get first unseen message
  $IMAP->select($FolderName) || die $@;
  $MsgId = $IMAP->search('not', 'seen')->[0];

  # Get message envelope and print some details
  $MsgEV = $IMAP->fetch($MsgId, 'envelope')->{$MsgId}->{envelope};
  print "From: " . $MsgEv->{From};
  print "To: " . $MsgEv->{To};
  print "Subject: " . $MsgEv->{Subject};

  # Get message body structure
  $MsgBS = $IMAP->fetch($MsgId, 'bodystructure')->{$MsgId}->{bodystructure};

  # Find imap part number of text part of message
  $MsgTxtHash = Mail::IMAPTalk::find_message($MsgBS);
  $MsgPart = $MsgTxtHash->{plain}->{'IMAP-Partnum'};

  # Retrieve message text body
  $MsgTxt = $IMAP->fetch($MsgId, "body[$MsgPart]")->{$MsgId}->{body};

  $IMAP->logout();

=head1 DESCRIPTION

This module communicates with an IMAP server. Each IMAP server command
is mapped to a method of this object.

Although other IMAP modules exist on CPAN, this has several advantages
over other modules.

=over 4

=item *

It parses the more complex IMAP structures like envelopes and body
structures into nice Perl data structures.

=item *

It correctly supports atoms, quoted strings and literals at any
point. Some parsers in other modules aren't fully IMAP compatiable
and may break at odd times with certain messages on some servers.

=item *

It allows large return values (eg. attachments on a message)
to be read directly into a file, rather than into memory.

=item *

It includes some helper functions to find the actual text/plain
or text/html part of a message out of a complex MIME structure.
It also can find a list of attachements, and CID links for HTML
messages with attached images.

=item *

It supports decoding of MIME headers to Perl utf-8 strings automatically,
so you don't have to deal with MIME encoded headers (enabled optionally).

=back

While the IMAP protocol does allow for asynchronous running of commands, this
module is designed to be used in a synchronous manner. That is, you issue a
command by calling a method, and the command will block until the appropriate
response is returned. The method will then return the parsed results from
the given command.

=cut

# Export {{{
require Exporter;
@ISA = qw(Exporter);
%EXPORT_TAGS = (
  Default => [ qw(get_body_part find_message build_cid_map) ]
);
Exporter::export_ok_tags('Default');

sub import {
  # Test for special case if need UTF8 support
  our $AlreadyLoadedEncode;
  if (@_>1 && $_[1] && $_[1] eq ':utf8support') {
    splice @_, 1, 1;
    if (!$AlreadyLoadedEncode) {
      eval "use Encode qw(decode);";
      $AlreadyLoadedEncode = 1;
    }
  }

  goto &Exporter::import;
}

our $VERSION = '1.03';
# }}}

# Use modules {{{
use Fcntl qw(:DEFAULT);
use Socket;
use IO::Select;
use IO::Handle;
use IO::Socket;
use Data::Dumper;
use strict;
# }}}

=head1 CLASS OVERVIEW

The object methods have been broken in several sections.

=head2 Sections

=over 4

=item CONSTANTS

Lists the available constants the class uses.

=item CONSTRUCTOR

Explains all the options available when constructing a new instance of the
C<Mail::IMAPTalk> class.

=item CONNECTION CONTROL METHODS

These are methods which control the overall IMAP connection object, such
as logging in and logging out, how results are parsed, how folder names and
message id's are treated, etc.

=item IMAP FOLDER COMMAND METHODS

These are methods to inspect, add, delete and rename IMAP folders on
the server.

=item IMAP MESSAGE COMMAND METHODS

These are methods to retrieve, delete, move and add messages to/from
IMAP folders.

=item HELPER METHODS

These are extra methods that users of this class might find useful. They
generally do extra parsing on returned structures to provide higher
level functionality.

=item INTERNAL METHODS

These are methods used internally by the C<Mail::IMAPTalk> object to get work
done. They may be useful if you need to extend the class yourself. Note that
internal methods will always 'die' if they encounter any errors.

=item INTERNAL SOCKET FUNCTIONS

These are functions used internally by the C<Mail::IMAPTalk> object 
to read/write data to/from the IMAP connection socket. The class does
its own buffering so if you want to read/write to the IMAP socket, you
should use these functions.

=item INTERNAL PARSING FUNCTIONS

These are functions used to parse the results returned from the IMAP server
into Perl style data structures.

=back

=head2 Method results

All methods return undef on failure. There are four main modes of failure:

=over 4

=item 1. An error occurred reading/writing to a socket. Maybe the server
closed it, or you're not connected to any server.

=item 2. An error occurred parsing the response of an IMAP command. This is
usually only a problem if your IMAP server returns invalid data.

=item 3. An IMAP command didn't return an 'OK' response.

=item 4. The socket read operation timed out waiting for a response from
the server.

=back

In each case, some readable form of error text is placed in $@, or you
can call the C<get_last_error()> method. For commands which return
responses (e.g. fetch, getacl, etc), the result is returned. See each
command for details of the response result. For commands
with no response but which succeed (e.g. setacl, rename, etc) the result
'ok' is generally returned.

=head2 Method parameters

All methods which send data to the IMAP server (e.g. C<fetch()>, C<search()>,
etc) have their arguments processed before they are sent. Arguments may be
specified in several ways:

=over 4

=item B<scalar>

The value is first checked and quoted if required. Values containing
[\000\012\015] are turned into literals, values containing
[\000-\040\{\} \%\*\"] are quoted by surrounding with a "..." pair
(any " themselves are turned into \").

=item B<file ref>

The contents of the file is sent as an IMAP literal. Note that
because IMAPTalk has to know the length of the file being sent,
this must be a true file reference that can be seeked and not
just some stream. The entire file will be sent regardless of the
current seek point.

=item B<array ref>

The array reference should contain only 2 items. The first item is a text
string which specifies what to do with the second item of the array ref.

=over 4

=item * 'Literal'

The string/data in the second item should be sent as an IMAP literal
regardless of the actually data in the string/data.

=item * 'NoQuote'

The string/data in the second item should be sent as is, no quoting will
occur, and the data won't be sent as quoted or as a literal regardless
of the contents of the string/data.

Examples:

    # Password is automatically quoted to "nasty%*\"passwd"
    $IMAP->login("joe", 'nasty%*"passwd');
    # Append $MsgTxt as string
    $IMAP->append("inbox", [ 'Literal', $MsgTxt ])
    # Append MSGFILE contents as new message
    $IMAP->append("inbox", \*MSGFILE ])

=back

=back

=cut

=head1 CONSTANTS

These constants relate to the standard 4 states that an IMAP connection can
be in. They are passed and returned from the C<state()> method. See RFC2060
for more details about IMAP connection states.

=over 4

=item I<Unconnected>

Current not connected to any server.

=item I<Connected>

Connected to a server, but not logged in.

=item I<Authenticated>

Connected and logged into a server, but not current folder.

=item I<Selected>

Connected, logged in and have 'select'ed a current folder.

=back

=cut

# Constants for the possible states the connection can be in {{{
# Object not connected
use constant Unconnected => 0;
# connected; not logged in
use constant Connected => 1;
# logged in; no mailbox selected
use constant Authenticated => 2;
# mailbox selected
use constant Selected => 3;

# What a link break is on the network connection
use constant LB => "\015\012";

# Regexps used to determine if header is MIME encoded
my $RFC1522Token = qr/[^\x00-\x1f\(\)\<\>\@\,\;\:\"\/\[\]\?\.\=\ ]+/;
my $NeedDecodeUTF8Regexp = qr/=\?$RFC1522Token\?$RFC1522Token\?[^\?]*\?=/;

# }}}

=head1 CONSTRUCTOR

=over 4

=cut

=item I<Mail::IMAPTalk-E<gt>new(%Options)>

Creates new Mail::IMAPTalk object. The following options are supported.

=item B<Connection Options>

=over 4

=item B<Server>

The hostname or IP address to connect to. This must be supplied unless
the B<Socket> option is supplied.

=item B<Port>

The port number on the host to connect to. Defaults to 143 if not supplied.

=item B<Socket>

An existing socket to use as the connection to the IMAP server. If you
supply the B<Socket> option, you should not supply a B<Server> or B<Port>
option.

This is useful if you want to create an SSL socket connection using
IO::Socket::SSL and then pass in the connected socket to the new() call.

It's also useful in conjunction with the C<release_socket()> method
described below for reusing the same socket beyond the lifetime of the IMAPTalk
object. See a description in the section C<release_socket()> method for
more information.

You must have write flushing enabled for any
socket you pass in here so that commands will actually be sent,
and responses received, rather than just waiting and eventually
timing out. you can do this using the Perl C<select()> call and
$| ($AUTOFLUSH) variable as shown below.

  my $ofh = select($Socket); $| = 1; select ($ofh);

=item B<State>

If you supply a C<Socket> option, you can specify the IMAP state the
socket is currently in, namely one of 'Unconnected', 'Connected',
'Authenticated' or 'Selected'. This defaults to 'Connected' if not
supplied and the C<Socket> option is supplied.

=item B<ExpectGreeting>

If supplied and true, and a socket is supplied via the C<Socket>
option, checks that a greeting line is supplied by the server
and reads the greeting line.

=back

=item B<Login Options>

=over 4

=item B<Username>

The username to connect to the IMAP server as. If not supplied, no login
is attempted and the IMAP object is left in the B<CONNECTED> state.
If supplied, you must also supply the B<Password> option and a login
is attempted. If the login fails, the connection is closed and B<undef>
is returned. If you want to do something with a connection even if the
login fails, don't pass a B<Username> option, but instead use the B<login>
method described below.

=item B<Password>

The password to use to login to the account.

=back

=item B<IMAP message/folder options>

=over 4

=item B<Uid>

Control whether message ids are message uids or not. This is 1 (on) by
default because generally that's how most people want to use it. This affects
most commands that require/use/return message ids (e.g. B<fetch>, B<search>,
B<sort>, etc) 

=item B<RootFolder>

If supplied, sets the root folder prefix. This is the same as calling
C<set_root_folder()> with the value passed. If no value is supplied,
C<set_root_folder()> is called with no value. See the C<set_root_folder()>
method for more details.

=item B<Separator>

If supplied, sets the folder name text string separator character. 
Passed as the second parameter to the C<set_root_folder()> method.

=item B<CaseInsensitive>

If supplied, passed along with RootFolder to the C<set_root_folder()>
method.

=item B<AltRootFolder>

If supplied, passed along with RootFolder to the C<set_root_folder()>
method.

=back

Examples:

  $imap = Mail::IMAPTalk->new(
            Server          => 'foo.com',
            Port            => 143,
            Username        => 'joebloggs',
            Password        => 'mypassword',
            Separator       => '.',
            RootFolder      => 'inbox',
            CaseInsensitive => 1)
          || die "Connection to foo.com failed. Reason: $@";

  $imap = Mail::IMAPTalk->new(
            Socket => $SSLSocket,
            State  => Mail::IMAPTalk::Authenticated,
            Uid    => 0)
          || die "Could not query on existing socket. Reason: $@";

=cut
sub new {
  my $Proto = shift;
  my $Class = ref($Proto) || $Proto;
  my %Args = @_;

  # Two main possible new() modes. Either connect to server
  #   or use existing socket passed
  $Args{Server} || $Args{Socket}
    || die "No 'Server' or 'Socket' specified";
  $Args{Server} && $Args{Socket}
    && die "Can not specify 'Server' and 'Socket' simultaneously";

  # Set ourself to empty to start with
  my $Self = {};
  bless ($Self, $Class);

  # Create new socket to server
  my $Socket;
  if ($Args{Server}) {

    # Set starting state
    $Self->state(Unconnected);

    my $Server = $Self->{Server} = $Args{Server} || die "No Server name given";
    my $Port = $Self->{Port} = $Args{Port} || 143;

    # Create a new socket and connect to IMAP server
    socket($Socket, PF_INET, SOCK_STREAM, getprotobyname('tcp'))
      || return undef;
    my $paddr = sockaddr_in($Port, inet_aton($Server));
    connect($Socket, $paddr) || return undef;
    
    # Force flushing after every write to the socket
    my $ofh = select($Socket); $| = 1; select ($ofh);

    # Set to connected state
    $Self->state(Connected);
  }

  # We have an existing socket
  else {
    # Copy socket
    $Socket = $Args{Socket};
    delete $Args{Socket};

    # Set state
    $Self->state(exists $Args{State} ? $Args{State} : Connected);
  }

  $Self->{Socket} = $Socket;

  # Save socket for later use and create IO::Select
  $Self->{Select} = IO::Select->new();
  $Self->{Select}->add($Socket);
  $Self->{LocalFD} = fileno($Socket);

  # Process greeting
  if ($Args{Server} || $Args{ExpectGreeting}) {
    $Self->{CmdId} = "*";
    my ($CompletionResp, $DataResp) = $Self->_parse_response('');
    return undef if $CompletionResp !~ /^ok/i;
  }

  # Start counter when sending commands
  $Self->{CmdId} = 1;

  # Set base modes
  $Self->uid($Args{Uid});
  $Self->parse_mode(Envelope => 1, BodyStructure => 1);
  $Self->set_tracing(0);

  # Login first if specified
  if ($Args{Username}) {
    # If login fails, just return undef
    $Self->login(@Args{'Username', 'Password'}) || return undef;
  }

  # Set root folder and separator (if supplied)
  $Self->set_root_folder(
    $Args{RootFolder}, $Args{Separator}, $Args{CaseInsensitive}, $Args{AltRootFolder});

  return $Self;
}

=back
=cut

=head1 CONNECTION CONTROL METHODS

=over 4
=cut

=item I<login($UserName, $Password)>

Attempt to login user specified username and password.

Currently there is only plain text password login support. If someone can
give me a hand implementing others (like DIGEST-MD5, CRAM-MD5, etc) please
contact me (see details below).

=cut
sub login {
  my $Self = shift;
  my ($User, $Pwd) = @_;
  my $PwdArr = ['DoQuote', $Pwd];

  # Call standard command. Return undef if login failed
  $Self->_imap_cmd("login", 0, "", $User, $PwdArr)
    || return undef;

  # Set to authenticated if successful
  $Self->state(Authenticated);

  return 1;
}

=item I<logout()>

Log out of IMAP server. This usually closes the servers connection as well.

=cut
sub logout {
  my $Self = shift;
  $Self->_imap_cmd('logout', 0, '');
  $Self->state(Unconnected);
  return 1;
}

=item I<state(optional $State)>

Set/get the current IMAP connection state. Returned or passed value should be
one of the constants (Unconnected, Connected, Authenticated, Selected).

=cut
sub state {
  my $Self = shift;
  $Self->{State} = $_[0] if defined $_[0];
  return (defined($Self->{State}) ? $Self->{State} : '');
}

=item I<uid(optional $UidMode)>

Get/set the UID status of all UID possible IMAP commands.
If set to 1, all commands that can take a UID are set to 'UID Mode',
where any ID sent to IMAPTalk is assumed to be a UID.

=cut
sub uid {
  $_[0]->{Uid} = $_[1];
  return 1;
}

=item I<capability()>

This method returns the IMAP servers capability command results.
The result is a hash reference of (lc(Capability) => 1) key value pairs.
This means you can do things like:

  if ($IMAP->capability()->{quota}) { ... }

to test if the server has the QUOTA capability. If you just want a list of
capabilities, use the Perl 'keys' function to get a list of keys from the
returned hash reference.

=cut
sub capability {
  my $Self = shift;

  # If we've already executed the capability command once, just return the results
  return $Self->{Cache}->{capability}
    if exists $Self->{Cache}->{capability};

  # Otherwise execute capability command
  my %Capability = map { lc($_), 1 } ($Self->_imap_cmd("capability", 0, "capability"));

  # Save for any future queries and return
  return ($Self->{Cache}->{capability} = \%Capability);
}

=item I<namespace()>

Returns the result of the IMAP servers namespace command.

=cut
sub namespace {
  my $Self = shift;

  # If we've already executed the capability command once, just return the results
  return $Self->{Cache}->{namespace}
    if exists $Self->{Cache}->{namespace};

  $Self->_require_capability('namespace') || return undef;

  # Otherwise execute capability command
  my $Namespace = $Self->_imap_cmd("namespace", 0, "namespace");

  # Save for any future queries and return
  return ($Self->{Cache}->{namespace} = $Namespace);
}

=item I<noop()>

Perform the standard IMAP 'noop' command which does nothing.

=cut
sub noop {
  my $Self = shift;
  return $Self->_imap_cmd("noop", 0, "", @_);
}

=item I<is_open()>

Returns true if the current socket connection is still open (e.g. the socket
hasn't been closed this end or the other end due to a timeout).

=cut
sub is_open {
  my $Self = shift;

  $Self->_trace("A: is_open test\n") if $Self->{Trace};

  while (1) {

    # Ensure no data was left in our own read buffer
    if ($Self->{ReadLine}) {
      $Self->_trace("A: unexpected data in read buffer - '" .$Self->{ReadLine}. "'\n")
        if $Self->{Trace};
      die "Unexpected data in read buffer '" . $Self->{ReadLine} . "'";
    }
    $Self->{ReadLine} = undef;

    # See if there's any data to read
    local $Self->{Timeout} = 0;

    # If no sockets with data, must be blocked, so must be connected
    my $Atom = eval { $Self->_next_atom(); };

    # If a timeout, socket is still connected and open
    if ($@ && ($@ =~ /timed out/)) {
      $Self->_trace("A: is_open test received timeout, still open\n")
        if $Self->{Trace};
      return 1;
    }

    # Other error, assume it's closed
    if ($@) {
      $Self->_trace("A: is_open test received error - $@\n")
        if $Self->{Trace};
      $Self->{Socket}->close();
      $Self->{Socket} = undef;
      $Self->state(Unconnected);
      return undef;
    }

    # There was something, find what it was
    $Atom = $Self->_remaining_line();

    $Self->_trace("A: is_open test returned data - '$Atom'\n")
      if $Self->{Trace};

    $Atom || die "Unexpected response while checking connection - $Atom";

    # If it's a bye, we're being closed
    if ($Atom =~ /^bye/i) {
      $Self->_trace("A: is_open test received 'bye' response\n")
        if $Self->{Trace};
      $Self->{Socket}->close();
      $Self->{Socket} = undef;
      $Self->state(Unconnected);
      return undef;
    }

    # Otherwise it was probably some sort of alert,
    #  check again
  }

}

=item I<set_root_folder($RootFolder, $Separator, optional $CaseInsensitive, $AltRoot)>

Change the root folder prefix. Some IMAP servers require that all user
folders/mailboxes live under a root folder prefix (current versions of
B<cyrus> for example use 'INBOX' for personal folders and 'user' for other
users folders). If no value is specified, it sets it to ''. You might
want to use the B<namespace()> method to find out what roots are
available. The $CaseInsensitive argument is a flag that determines
whether the root folder should be matched in a case sensitive or
insensitive way. See below.

Setting this affects all commands that take a folder argument. Basically
if the foldername begins with root folder prefix (case sensitive or
insensitive based on the second argument), it's left as is,
otherwise the root folder prefix and separator char are prefixed to the
folder name.

Examples:

  # This is what cyrus uses
  $IMAP->set_root_folder('inbox', '.', 1, 'user');

  # Selects 'Inbox' (because 'Inbox' eq 'inbox' case insensitive)
  $IMAP->select('Inbox');      
  # Selects 'inbox.blah'
  $IMAP->select('blah');
  # Selects 'INBOX.fred' (because 'INBOX' eq 'inbox' case insensitive)
  #IMAP->select('INBOX.fred'); # Selects 'INBOX.fred'
  # Selects 'user.john' (because 'user' is alt root)
  #IMAP->select('user.john'); # Selects 'user.john'

=cut
sub set_root_folder {
  my ($Self, $RootFolder, $Separator, $CaseInsensitive, $AltRootFolder) = @_;

  $RootFolder = '' if !defined($RootFolder);
  $Separator = '' if !defined($Separator);
  $AltRootFolder = '' if !defined($AltRootFolder);

  # Strip of the Separator, if the IMAP-Server already appended it
  $RootFolder =~ s/\Q$Separator\E$//;

  $Self->{RootFolder} = $RootFolder;
  $Self->{AltRootFolder} = $AltRootFolder;
  $Self->{Separator} = $Separator;
  $Self->{RootPrefix} = $RootFolder . $Separator;
  $Self->{CaseInsensitive} = $CaseInsensitive;

  my $RootPrefix = $RootFolder . $Separator;

  if ($RootFolder) {
    # Quote any special chars
    $RootFolder =~ s/([^\w])/\\$1/g;
    $Separator =~ s/([^\w])/\\$1/g;
    $AltRootFolder =~ s/([^\w])/\\$1/g;

    # Make folder name search RootFolder|AltRootFolder
    $AltRootFolder = '|^(?:' . $AltRootFolder . "(?:\\z|$Separator))" if $AltRootFolder;

    # Make sure we match these forms:
    #  inbox
    #  inbox.
    #  inbox.blah
    # And not these forms
    #  inbo
    #  inboxen
    if ($CaseInsensitive) {
      $Self->{RootFolderMatch} = qr/^(?:${RootFolder}\z)${AltRootFolder}/i;
      $Self->{RootFolderMatch2} = qr/^${RootFolder}${Separator}/i;
    } else {
      $Self->{RootFolderMatch} = qr/^(?:${RootFolder})${AltRootFolder}/;
      $Self->{RootFolderMatch2} = qr/^${RootFolder}${Separator}/;
    }
  } else {
    $Self->{RootFolderMatch} = undef;
    $Self->{RootFolderMatch2} = undef;
  }

  return 1;
}

=item I<_set_separator($Separator)>

Checks if the given separator is the same as the one we used before.
If not, it calls set_root_folder to recreate the settings with the new
Separator.

=cut
sub _set_separator {
  my ($Self,$Separator) = @_;

  #Nothing to do, if we have the same Separator as before
  return 1 if (defined($Separator) && ($Self->{Separator} eq $Separator));
  return $Self->set_root_folder($Self->{RootFolder}, $Separator,
                                $Self->{CaseInsensitive}, $Self->{AltRootFolder});
}

=item I<literal_handle_control(optional $FileHandle)>

Sets the mode whether to read literals as file handles or scalars.

You should pass a filehandle here that any literal will be read into. To
turn off literal reads into a file handle, pass a 0.

Examples:

  # Read rfc822 text of message 3 into file
  # (note that the file will have /r/n line terminators)
  open(F, ">messagebody.txt");
  $IMAP->literal_handle_control(\*F);
  $IMAP->fetch(3, 'rfc822');
  $IMAP->literal_handle_control(0);

=cut
sub literal_handle_control {
  my $Self = shift;
  $Self->{LiteralControl} = $_[0] if defined $_[0];
  return $Self->{LiteralControl} ? 1 : 0;
}

=item I<release_socket()>

Release IMAPTalk's ownership of the current socket it's using so it's not
disconnected on DESTROY. This returns the socket, and makes sure that the 
IMAPTalk object doesn't hold a reference to it any more. 
This means you can't call any methods on the IMAPTalk object any more.  

=cut
sub release_socket {
  my $Self = shift;

  # Remove from the select object
  $Self->{Select}->remove($Self->{Socket}) if ref($Self->{Select});
  my $Socket = $Self->{Socket};

  # Delete any knowledge of the socket in our instance
  delete $Self->{Socket};
  delete $Self->{Select};

  $Self->_trace("A: Release socket, fileno=" . fileno($Socket) . "\n")
    if $Self->{Trace};

  return $Socket;
}

=item I<get_last_error()>

Returns a text string which describes the last error that occurred.

=cut
sub get_last_error {
  my $Self = shift;
  return $Self->{LastError};
}

=item I<get_response_code($Response)>

Returns the extra response data generated by a previous call. This is
most often used after calling B<select> which usually generates some
set of the following sub-results.

=over 4

=item * B<permanentflags>

Array reference of flags which are stored permanently.

=item * B<uidvalidity>

Whether the current UID set is valid. See the IMAP RFC for more
information on this. If this value changes, then all UIDs in the folder
have been changed.

=item * B<uidnext>

The next UID number that will be assigned.

=item * B<exists>

Number of messages that exist in the folder.

=item * B<recent>

Number of messages that are recent in the folder.

=back

Other possible responses are B<alert>, B<newname>, B<parse>,
B<trycreate>, B<appenduid>.

Examples:

  # Select inbox and get list of permanent flags, uidnext and number
  #  of message in the folder
  $IMAP->select('inbox');
  my $NMessages = $IMAP->get_sub_result('exists');
  my $PermanentFlags = $IMAP->get_sub_result('permanentflags');
  my $UidNext = $IMAP->get_sub_result('uidnext');

=cut
sub get_response_code {
  my ($Self, $Response) = @_;
  return $Self->{Cache}->{$Response};
}

=item I<clear_reponse_code($Response)>

Clears any response code information. Response code information
is not normally cleared between calls.

=cut
sub clear_response_code {
  my ($Self, $Response) = @_;
  delete $Self->{Cache}->{$Response};
  return 1;
}

=item I<parse_mode(ParseOption =E<gt> $ParseMode)>

Changes how results of fetch commands are parsed. Available
options are:

=over 4

=item I<BodyStructure>

Parse bodystructure into more Perl-friendly structure
See the B<FETCH RESULTS> section.

=item I<Envelope>

Parse envelopes into more Perl-friendly structure
See the B<FETCH RESULTS> section.

=item I<EnvelopeRaw>

If parsing envelopes, create To/Cc/Bcc and
Raw-To/Raw-Cc/Raw-Bcc entries which are array refs of 4
entries each as returned by the IMAP server.

=item I<DecodeUTF8>

If parsing envelopes, decode any MIME encoded headers into
Perl UTF-8 strings.

For this to work, you must have 'used' Mail::IMAPTalk with:

use Mail::IMAPTalk qw(:utf8support ...)

=back

=cut
sub parse_mode {
  my $Self = shift;

  my $ParseMode = $Self->{ParseMode} || {};
  $Self->{ParseMode} = { %$ParseMode, @_ };

}

=item I<set_tracing($Tracer, $ClearEachCmd)>

Allows you to trace both IMAP input and output sent to the server
and returned from the server. This is useful for debugging. Returns
the previous value of the tracer and then sets it to the passed
value. Possible values for $Tracer are:

=over 4

=item I<0>

Disable all tracing.

=item I<1>

Print to STDERR.

=item I<Code ref>

Call code ref for each line input and output. Pass line as parameter.

=item I<Glob ref>

Print to glob.

=item I<Scalar ref>

Appends to the referenced scalar.

=back

Note: literals are never passed to the tracer.

If $ClearEachCmd is set, and a scalar ref is used, then the
scalar ref value is cleared to '' at the start of each
command. This allows you to trace, but only keep details for
the last issued command in the trace variable

=cut
sub set_tracing {
  my $Self = shift;
  my $OldTrace = $Self->{Trace};
  $Self->{Trace} = shift;
  $Self->{ClearEachCmd} = shift;
  return $OldTrace;
}

=item I<set_callbacks(Callback =E<gt> sub { }, [ ... Callback =E<gt> sub { } ], ... )>

Allows you to set callbacks when certain functions are called.
This can be useful for keep track of certain actions so you
can work out if a folder's message count or size is invalid.

=over 4

=item I<OnFolderChange($Folder)>

Called if a message is added to/deleted from a folder.

=back

=cut
sub set_callbacks {
  my $Self = shift;
  my %CallBacks = @_;

  while (my ($CB, $Sub) = each %CallBacks) {
    $Self->{CallBacks}->{$CB} = $Sub;
  }

  return 1;
}

=back
=cut

=head1 IMAP FOLDER COMMAND METHODS

B<Note:> In all cases where a folder name is used, 
the folder name is first manipulated according to the current root folder
prefix as described in C<set_root_folder()>.

=over 4
=cut

=item I<select($FolderName, $ReadOnly)>

Perform the standard IMAP 'select' command to select a folder for
retrieving/moving/adding messages. If $ReadOnly is defined, the 
IMAP EXAMINE verb is used instead of SELECT.

=cut
sub select {
  my ($Self, $Folder, $ReadOnly) = @_;

  # Fix the folder name to include the root suffix
  $Folder = $Self->_fix_folder_name($Folder);

  # Are we already selected and in the same mode?
  if ($Self->state() == Selected &&
      $Folder eq $Self->{CurrentFolder} &&
      ($ReadOnly ? 'read-only' : 'read-write') eq $Self->{CurrentFolderMode}) {
    return 1;
  }

  $Self->clear_response_code('READ-ONLY');
  $Self->clear_response_code('READ-WRITE');

  # Do select command
  my $Res = $Self->_imap_cmd(defined($ReadOnly) ? "examine" : "select", 0, "", $Folder);
  if ($Res) {
    # Set internal current folder and mode
    $Self->{CurrentFolder} = $Folder;
    $Self->{CurrentFolderMode} = $Self->get_response_code('foldermode');
    # Set to selected state
    $Self->state(Selected);
    return $Self->{CurrentFolderMode} || $Self->{LastRespCode};
  } else {
    $Self->{CurrentFolder} = "";
    $Self->{LastError} = $@ = "Select failed for folder '$Folder' : $Self->{LastError}";
  }
  
  return undef;
}

=item I<unselect()>

Performs the standard IMAP unselect command.

=cut
sub unselect {
  my $Self = shift;

  my $Res = $Self->_imap_cmd("unselect", 0, "", @_);

  # Clear cached information about current folder
  if ($Res) {
    $Self->{CurrentFolder} = '';
    $Self->{CurrentFolderMode} = 0;
    $Self->state(Authenticated);
  }
  return $Res;
}

=item I<examine($FolderName)>

Perform the standard IMAP 'examine' command to select a folder in read only
mode for retrieving messages. This is the same as C<select($FolderName, 1)>.
See C<select()> for more details.

=cut
sub examine {
  return $_[0]->select($_[1], 1);
}

=item I<create($FolderName)>

Perform the standard IMAP 'create' command to create a new folder.

=cut
sub create {
  my $Self = shift;
  $Self->{CurrentFolder} = "";
  my $FolderName = $Self->_fix_folder_name(+shift);
  $Self->_signal('OnFolderChange', $FolderName);
  return $Self->_imap_cmd("create", 0, "", $FolderName, @_);
}

=item I<delete($FolderName)>

Perform the standard IMAP 'delete' command to delete a folder.

=cut
sub delete {
  my $Self = shift;
  $Self->{CurrentFolder} = "";
  my $FolderName = $Self->_fix_folder_name(+shift);
  $Self->_signal('OnFolderChange', $FolderName);
  return $Self->_imap_cmd("delete", 0, "", $FolderName, @_);
}

=item I<rename($OldFolderName, $NewFolderName)>

Perform the standard IMAP 'rename' command to rename a folder.

=cut
sub rename {
  my $Self = shift;
  $Self->{CurrentFolder} = "";
  my $FolderName1 = $Self->_fix_folder_name(+shift);
  my $FolderName2 = $Self->_fix_folder_name(+shift);
  $Self->_signal('OnFolderChange', $FolderName1);
  $Self->_signal('OnFolderChange', $FolderName2);
  return $Self->_imap_cmd("rename", 0, "", $FolderName1, $FolderName2, @_);
}

=item I<list($Reference, $Name)>

Perform the standard IMAP 'list' command to return a list of available
folders.

=cut
sub list {
  my $Self = shift;
  return $Self->_imap_cmd("list", 0, "list", @_);
}

=item I<lsub($Reference, $Name)>

Perform the standard IMAP 'lsub' command to return a list of subscribed
folders

=cut
sub lsub {
  my $Self = shift;
  return $Self->_imap_cmd("lsub", 0, "lsub", @_);
}

=item I<subscribe($FolderName)>

Perform the standard IMAP 'subscribe' command to subscribe to a folder.

=cut
sub subscribe {
  my $Self = shift;
  my $FolderName = $Self->_fix_folder_name(+shift);
  return $Self->_imap_cmd("subscribe", 0, "", $FolderName);
}

=item I<unsubscribe($FolderName)>

Perform the standard IMAP 'unsubscribe' command to unsubscribe from a folder.

=cut
sub unsubscribe {
  my $Self = shift;
  my $FolderName = $Self->_fix_folder_name(+shift);
  return $Self->_imap_cmd("unsubscribe", 0, "", $FolderName);
}

=item I<check()>

Perform the standard IMAP 'check' command to checkpoint the current folder.

=cut
sub check {
  my $Self = shift;
  return $Self->_imap_cmd("check", 0, "", @_);
}

=item I<setacl($FolderName, $User, $Rights)>

Perform the IMAP 'setacl' command to set the access control list
details of a folder/mailbox. See RFC2086 for more details on the IMAP
ACL extension. $User is the user name to set the access
rights for. $Rights is either a list of absolute rights to set, or a
list prefixed by a - to remove those rights, or a + to add those rights.

=over 4

=item l - lookup (mailbox is visible to LIST/LSUB commands)

=item r - read (SELECT the mailbox, perform CHECK, FETCH, PARTIAL, SEARCH, COPY from mailbox)

=item s - keep seen/unseen information across sessions (STORE SEEN flag)

=item w - write (STORE flags other than SEEN and DELETED)

=item i - insert (perform APPEND, COPY into mailbox)

=item p - post (send mail to submission address for mailbox, not enforced by IMAP4 itself)

=item c - create (CREATE new sub-mailboxes in any implementation-defined hierarchy)

=item d - delete (STORE DELETED flag, perform EXPUNGE)

=item a - administer (perform SETACL)

=back

The standard access control configurations for cyrus are

=over 4

=item read   = "lrs"

=item post   = "lrsp"

=item append = "lrsip"

=item write  = "lrswipcd"

=item all    = "lrswipcda"

=back

Examples:

  # Get full access for user 'joe' on his own folder
  $IMAP->setacl('user.joe', 'joe', 'lrswipcda') || die "IMAP error: $@";
  # Remove write, insert, post, create, delete access for user 'andrew'
  $IMAP->setacl('user.joe', 'andrew', '-wipcd') || die "IMAP error: $@";
  # Add lookup, read, keep unseen information for user 'paul'
  $IMAP->setacl('user.joe', 'paul', '+lrs') || die "IMAP error: $@";

=cut
sub setacl {
  my $Self = shift;
  $Self->_require_capability('acl') || return undef;
  return $Self->_imap_cmd("setacl", 0, "", $Self->_fix_folder_name(+shift), @_);
}

=item I<getacl($FolderName)>

Perform the IMAP 'getacl' command to get the access control list
details of a folder/mailbox. See RFC2086 for more details on the IMAP
ACL extension. Returns an array of pairs. Each pair is
a username followed by the access rights for that user. See B<setacl>
for more information on access rights.

Examples:

  my $Rights = $IMAP->getacl('user.joe') || die "IMAP error : $@";
  $Rights = [
    'joe', 'lrs',
    'andrew', 'lrswipcda'
  ];

  $IMAP->setacl('user.joe', 'joe', 'lrswipcda') || die "IMAP error : $@";
  $IMAP->setacl('user.joe', 'andrew', '-wipcd') || die "IMAP error : $@";
  $IMAP->setacl('user.joe', 'paul', '+lrs') || die "IMAP error : $@";

  $Rights = $IMAP->getacl('user.joe') || die "IMAP error : $@";
  $Rights = [
    'joe', 'lrswipcd',
    'andrew', 'lrs',
    'paul', 'lrs'
  ];

=cut
sub getacl {
  my $Self = shift;
  $Self->_require_capability('acl') || return undef;
  return $Self->_imap_cmd("getacl", 0, "", $Self->_fix_folder_name(+shift), @_);
}

=item I<deleteacl($FolderName, $Username)>

Perform the IMAP 'deleteacl' command to delete all access
control information for the given user on the given folder. See B<setacl>
for more information on access rights.

Examples:

  my $Rights = $IMAP->getacl('user.joe') || die "IMAP error : $@";
  $Rights = [
    'joe', 'lrswipcd',
    'andrew', 'lrs',
    'paul', 'lrs'
  ];

  # Delete access information for user 'andrew'
  $IMAP->deleteacl('user.joe', 'andrew') || die "IMAP error : $@";

  $Rights = $IMAP->getacl('user.joe') || die "IMAP error : $@";
  $Rights = [
    'joe', 'lrswipcd',
    'paul', 'lrs'
  ];

=cut
sub deleteacl {
  my $Self = shift;
  $Self->_require_capability('acl') || return undef;
  return $Self->_imap_cmd("deleteacl", 0, "", $Self->_fix_folder_name(+shift), @_);
}

=item I<setquota($FolderName, $QuotaDetails)>

Perform the IMAP 'setquota' command to set the usage quota
details of a folder/mailbox. See RFC2087 for details of the IMAP
quota extension. $QuotaDetails is a bracketed list of limit item/value
pairs which represent a particular type of limit and the value to set
it to. Current limits are:

=over 4

=item STORAGE - Sum of messages' RFC822.SIZE, in units of 1024 octets

=item MESSAGE - Number of messages

=back

Examples:

  # Set maximum size of folder to 50M and 1000 messages
  $IMAP->setquota('user.joe', '(storage 50000)') || die "IMAP error: $@";
  $IMAP->setquota('user.john', '(messages 1000)') || die "IMAP error: $@";
  # Remove quotas
  $IMAP->setquota('user.joe', '()') || die "IMAP error: $@";

=cut
sub setquota {
  my $Self = shift;
  $Self->_require_capability('quota') || return undef;
  return $Self->_imap_cmd("setquota", 0, "", $Self->_fix_folder_name(+shift), @_);
}

=item I<getquota($FolderName)>

Perform the standard IMAP 'getquota' command to get the quota
details of a folder/mailbox. See RFC2087 for details of the IMAP
quota extension. Returns an array reference to quota limit triplets.
Each triplet is made of: limit item, current value, maximum value.

Note that this only returns the quota for a folder if it actually
has had a quota set on it. It's possible that a parent folder
might have a quota as well which affects sub-folders. Use the
getquotaroot to find out if this is true.

Examples:

  my $Result = $IMAP->getquota('user.joe') || die "IMAP error: $@";
  $Result = [
    'STORAGE', 31, 50000,
    'MESSAGE', 5, 1000
  ];

=cut
sub getquota {
  my $Self = shift;
  $Self->_require_capability('quota') || return undef;
  my $Folder = $Self->_fix_folder_name(+shift);
  my @Res = $Self->_imap_cmd("getquota", 0, "", $Folder, @_);
  return (ref($Res[0]) eq 'HASH') ? @{$Res[0]->{$Folder}} : @Res;
}

=item I<getquotaroot($FolderName)>

Perform the IMAP 'getquotaroot' command to get the quota
details of a folder/mailbox and possible root quota as well.
See RFC2087 for details of the IMAP
quota extension. The result of this command is a little complex.
Unfortunately it doesn't map really easily into any structure
since there are several different responses. 

Basically it's a hash reference. The 'quotaroot' item is the
response which lists the root quotas that apply to the given
folder. The first item is the folder name, and the remaining
items are the quota root items. There is then a hash item
for each quota root item. It's probably easiest to look at
the example below.

Examples:

  my $Result = $IMAP->getquotaroot('user.joe.blah') || die "IMAP error: $@";
  $Result = {
    'quotaroot' => [
      'user.joe.blah', 'user.joe', ''
    ],
    'user.joe' => [
      'STORAGE', 31, 50000,
      'MESSAGES', 5, 1000
    ],
    '' => [
      'MESSAGES', 3498, 100000
    ]
  };

=cut
sub getquotaroot {
  my $Self = shift;
  $Self->_require_capability('quota') || return undef;
  return $Self->_imap_cmd("getquotaroot", 0, "", $Self->_fix_folder_name(+shift), @_);
}

=item I<message_count($FolderName)>

Return the number of messages in a folder. See also C<status()> for getting
more information about messages in a folder.

=cut
sub message_count {
  my $Self = shift;
  my $Res = $Self->status(+shift, '(messages)') || return undef;
  return $Res->{messages};
}

=item I<status($FolderName, $StatusList)>

Perform the standard IMAP 'status' command to retrieve status information about
a folder/mailbox.

The $StatusList is a bracketed list of folder items to obtain the status of.
Can contain: messages, recent, uidnext, uidvalidity, unseen.

The return value is a hash reference of lc(status-item) => value.

Examples:

  my $Res = $IMAP->status('inbox', '(MESSAGES UNSEEN)');

  $Res = {
    'messages' => 8,
    'unseen' => 2
  };

=cut
sub status {
  my $Self = shift;
  my $Msgs = ($Self->_imap_cmd("status", 0, "status", $Self->_fix_folder_name(+shift), +shift)) || return undef;
  return _parse_list_to_hash($Msgs->[1]);
}

=item I<multistatus($StatusList, @FolderNames)>

Performs many IMAP 'status' commands on a list of folders. Sends all the
commands at once and wait for responses. This speeds up latency issues.

Returns a hash ref of folder name => status results.

=cut
sub multistatus {
  my ($Self, $Items, @FolderList) = @_;

  # Send all commands at once
  my $FirstId = $Self->{CmdId};
  for (@FolderList) {
    $Self->_send_cmd("status", $Self->_fix_folder_name($_), $Items);
    $Self->{CmdId}++;
  }

  # Parse responses
  my %Resp;
  $Self->{CmdId} = $FirstId;
  for (@FolderList) {
    my ($CompletionResp, $DataResp) = $Self->_parse_response("status");
    $Resp{$_} = ref($DataResp) ? _parse_list_to_hash($DataResp->[1]) : $CompletionResp;
    $Self->{CmdId}++;
  }

  return \%Resp;
}

=item I<getannotation($FolderName, $Entry, $Attribute)>

Perform the IMAP 'getannotation' command to get the annotation(s)
for a mailbox.  See imap-annotatemore extension for details.

Examples:

  my $Result = $IMAP->getannotation('user.joe.blah', '/*' '*') || die "IMAP error: $@";
  $Result = {
    'user.joe.blah' => {
      '/vendor/cmu/cyrus-imapd/size' => {
        'size.shared' => '5',
        'content-type.shared' => 'text/plain',
        'value.shared' => '19261'
      },
      '/vendor/cmu/cyrus-imapd/lastupdate' => {
        'size.shared' => '26',
        'content-type.shared' => 'text/plain',
        'value.shared' => '26-Mar-2004 13:31:56 -0800'
      },
      '/vendor/cmu/cyrus-imapd/partition' => {
        'size.shared' => '7',
        'content-type.shared' => 'text/plain',
        'value.shared' => 'default'
      }
    }
  };

=cut
sub getannotation {
  my $Self = shift;
  $Self->_require_capability('annotatemore') || return undef;
  return $Self->_imap_cmd("getannotation", 0, "", $Self->_fix_folder_name(+shift, 1), _quote_list(@_));
}

=item I<setannotation($FolderName, $Entry, $Attribute, [ $Entry, $Attribute ], ... )>

Perform the IMAP 'setannotation' command to get the annotation(s)
for a mailbox.  See imap-annotatemore extension for details.

Examples:

  my $Result = $IMAP->setannotation('user.joe.blah', '/comment', [ 'value.priv' 'A comment' ])
    || die "IMAP error: $@";

=cut
sub setannotation {
  my $Self = shift;
  $Self->_require_capability('annotatemore') || return undef;
  return $Self->_imap_cmd("setannotation", 0, "", $Self->_fix_folder_name(+shift, 1), _quote_list(@_));
}

=item I<close()>

Perform the standard IMAP 'close' command to expunge deleted messages
from the current folder and return to the Authenticated state.

=cut
sub close {
  my $Self = shift;
  $Self->_imap_cmd("close", 0, "", @_) || return undef;
  $Self->state(Authenticated);
}

=back
=cut

=head1 IMAP MESSAGE COMMAND METHODS

=over 4
=cut

=item I<fetch($MessageIds, $MessageItems)>

Perform the standard IMAP 'fetch' command to retrieve the specified message
items from the specified message IDs.

C<$MessageIds> can be one of two forms:

=over 4

=item 1.

A text string with a comma separated list of message ID's or message ranges
separated by colons. A '*' represents the highest message number.

Examples:

=over 4

=item * '1' - first message

=item * '1,2,5'

=item * '1:*' - all messages

=item * '1,3:*' - all but message 2

=back

Note that , separated lists and : separated ranges can be mixed, but to
make sure a certain hack works, if a '*' is used, it must be the last
character in the string.

=item 2.

An array reference with a list of message ID's or ranges. The array contents
are C<join(',', ...)>ed together.

=back

Note: If the C<uid()> state has been set to true, then all message ID's
must be message UIDs.

C<$MessageItems> can be one of, or a bracketed list of:

=over 4

=item * uid

=item * flags

=item * internaldate

=item * envelope

=item * bodystructure

=item * body

=item * body[section]<partial>

=item * body.peek[section]<partial>

=item * rfc822

=item * rfc822.header

=item * rfc822.size

=item * rfc822.text

=item * fast

=item * all

=item * full

=back

It would be a good idea to see RFC2060 for what all these means.

Examples:

  my $Res = $IMAP->fetch('1:*', 'rfc822.size');
  my $Res = $IMAP->fetch([1,2,3], '(bodystructure envelope)');

Return results:

The results returned by the IMAP server are parsed into a Perl structure.
See the section B<FETCH RESULTS> for all the interesting details.

For some servers (cyrus at least), if you do a fetch on a message id
which doesn't exist, you still get an OK response. I didn't feel this
was really very useful so if no data was retrieved, undef is returned.

=cut
sub fetch {
  my $Self = shift;

  # Clear any existing fetch responses and call the fetch command
  $Self->{Responses}->{fetch} = undef;
  my $FetchRes = $Self->_imap_cmd("fetch", 1, "fetch", _fix_message_ids(+shift), @_);

  # Fetch returns 'OK Completed' even if no message was found. I think
  #  it should be an error really
  if (!ref($FetchRes)) {
    $Self->{LastError} = $@ = "No fetch data returned. " . ($Self->{LastError}||'');
    return undef;
  }

  return $FetchRes;
}

=item I<copy($MsgIds, $ToFolder)>

Perform standard IMAP copy command to copy a set of messages from one folder
to another.

=cut
sub copy {
  my $Self = shift;
  my $Uids = _fix_message_ids(+shift);
  my $FolderName = $Self->_fix_folder_name(+shift);
  $Self->_signal('OnFolderChange', $FolderName);
  return $Self->_imap_cmd("copy", 1, "", $Uids, $FolderName, @_);
}

=item I<append($FolderName, optional $MsgFlags, optional $MsgDate, $MessageData)>

Perform standard IMAP append command to append a new message into a folder.

The $MessageData to append can either be a Perl scalar containing the data,
or a file handle to read the data from. In each case, the data must be in
proper RFC822 format with \r\n line terminators.

Any optional fields not needed should be removed, not left blank.

Examples:

  # msg.txt should have \r\n line terminators
  open(F, "msg.txt");
  $IMAP->append('inbox', \*F);

  my $MsgTxt =<<MSG;
  From: blah\@xyz.com
  To: whoever\@whereever.com
  ...
  MSG

  $MsgTxt =~ s/\n/\015\012/g;
  $IMAP->append('inbox', [ 'Literal', $MsgTxt ]);

=cut
sub append {
  my $Self = shift;
  my $FolderName = $Self->_fix_folder_name(+shift);
  $Self->_signal('OnFolderChange', $FolderName);
  return $Self->_imap_cmd("append", 0, "", $FolderName, @_);
}

=item I<search($MsgIdSet, @SearchCriteria)>

Perform standard IMAP search command. The result is an array reference to a list
of message IDs (or UIDs if in Uid mode) of messages that are in the $MsgIdSet
and also meet the search criteria.

@SearchCriteria is a list of search specifications, for example to look for
ASCII messages bigger than 2000 bytes you would set the list to be:

  my @SearchCriteria = ('CHARSET', 'US-ASCII', 'LARGER', '2000');

Examples:

  my $Res = $IMAP->search('1:*', 'NOT', 'DELETED');
  $Res = [ 1, 2, 5 ];

=cut
sub search {
  return (+shift)->_imap_cmd("search", 1, "search", _fix_message_ids(+shift), @_);
}

=item I<store($MsgIdSet, $FlagOperation, $Flags)>

Perform standard IMAP store command. Changes the flags associated with a
set of messages.

Examples:

  $IMAP->store('1:*', '+flags', '(\\deleted)');
  $IMAP->store('1:*', '-flags.silent', '(\\read)');

=cut
sub store {
  my $Self = shift;
  $Self->_signal('OnFolderChange', $Self->{CurrentFolder});
  return $Self->_imap_cmd("store", 1, "", _fix_message_ids(+shift), @_);
}

=item I<expunge()>

Perform standard IMAP expunge command. This actually deletes any messages
marked as deleted.

=cut
sub expunge {
  my $Self = shift;
  $Self->_signal('OnFolderChange', $Self->{CurrentFolder});
  return $Self->_imap_cmd("expunge", 0, "", @_);
}

=item I<uidexpunge($MsgIdSet)>

Perform IMAP uid expunge command as per RFC 2359.

=cut
sub uidexpunge {
  my $Self = shift;
  $Self->_signal('OnFolderChange', $Self->{CurrentFolder});
  return $Self->_imap_cmd("uid expunge", 0, "", _fix_message_ids(+shift));
}

=item I<sort($SortField, $CharSet, @SearchCriteria)>

Perform extension IMAP sort command. The result is an array reference to a list
of message IDs (or UIDs if in Uid mode) in sorted order.

It would probably be a good idea to look at the sort extension details at
somewhere like : http://www.imap.org/papers/docs/sort-ext.html.

Examples:

  my $Res = $IMAP->sort('(subject)', 'US-ASCII', 'NOT', 'DELETED');
  $Res = [ 5, 2, 3, 1, 4 ];

=cut
sub sort {
  return (+shift)->_imap_cmd("sort", 1, "sort", @_);
}

=item I<thread($ThreadType, $CharSet, @SearchCriteria)>

Perform extension IMAP thread command. The $ThreadType should be one
of 'REFERENCES' or 'ORDEREDSUBJECT'. You should check the C<capability()>
of the server to see if it supports one or both of these.

Examples

  my $Res = $IMAP->thread('REFERENCES', 'US-ASCII', 'NOT', 'DELETED');
  $Res = [ [10, 15, 20], [11], [ [ 12, 16 ], [13, 17] ];

=cut
sub thread {
  return (+shift)->_imap_cmd("thread", 1, "thread", @_);
}

=item I<fetch_flags($MessageIds)>

Perform an IMAP 'fetch flags' command to retrieve the specified flags
for the specified messages.

This is just a special fast path version of C<fetch>.

=cut
sub fetch_flags {
  my $Self = shift;

  my $Cmd = $Self->{Uid} ? 'uid fetch' : 'fetch';
  $Self->_send_cmd($Cmd, _fix_message_ids(+shift), '(flags)');

  my ($Tag, $MsgId, %FetchRes);

  $_ = $Self->_imap_socket_read_line();
  ($Tag, $MsgId, $_) = (/^(\S+) (\S+) \S+(?: \((.*)\))?/);
  while ($Tag ne $Self->{CmdId}) {
    my ($Uid) = /UID (\d+)/i;
    my ($Flags) = /FLAGS \((.*)\)/i;
    $FetchRes{$Uid} = { uid => $Uid, flags => [ split ' ', $Flags ] };
    $_ = $Self->_imap_socket_read_line();
    ($Tag, $MsgId, $_) = (/^(\S+) (\S+) \S+(?: \((.*)\))?/);
  }

  return \%FetchRes;
}

=back
=cut

=head1 IMAP HELPER FUNCTIONS

=over 4
=cut

=item I<get_body_part($BodyStruct, $PartNum)>

This is a helper function that can be used to further parse the
results of a fetched bodystructure. Given a top level body
structure, and a part number, it returns the reference to
the bodystructure sub part which that part number refers to.

Examples:

  # Fetch body structure
  my $FR = $IMAP->fetch(1, 'bodystructure');
  my $BS = $FR->{1}->{bodystructure};

  # Parse further to find particular sub part
  my $P12 = $IMAP->get_body_part($BS, '1.2');
  $P12->{'IMAP->Partnum'} eq '1.2' || die "Unexpected IMAP part number";

=cut
sub get_body_part {
  my ($BS, $PartNum) = @_;

  my @PartNums = split(/\./, $PartNum);

  # This is a hack for special messages where the first entity
  #   is a message/rfc822 type. In which case, we have to strip
  #   the first item
  my $IsFirst = 1;

  while (1) {
    # Go no further if we found what we want
    return $BS
      if $BS->{'IMAP-Partnum'} eq $PartNum;

    # Has to have sub-parts, either mime-multipart or rfc822 sub-message
    return undef
      if (!$BS) ||
         (!@PartNums) ||
         (!exists $BS->{'MIME-Subparts'} &&
          !exists $BS->{'Message-Bodystructure'});

    # Get sub-part
    if (exists $BS->{'Message-Bodystructure'}) {
      $BS = $BS->{'Message-Bodystructure'};
      shift(@PartNums) if $IsFirst;
    }
    $BS = ($BS->{'MIME-Subparts'} || [])->[shift(@PartNums)-1] || $BS;
    $IsFirst = 0;
  }
}

=item I<find_message($BodyStruct)>

This is a helper function that can be used to further parse the
results of a fetched bodystructure. It returns a hash reference
which always contains a 'text' item, and possibly an 'html'
item. In each case, the values of each hash item are references
into the body structure of the corresponding message part.

Examples:

  # Fetch body structure
  my $FR = $IMAP->fetch(1, 'bodystructure');
  my $BS = $FR->{1}->{bodystructure};

  # Parse further to find message components
  my $MC = $IMAP->find_message($BS);
  $MC = { 'plain' => ... text body struct ref part ...,
          'html' => ... html body struct ref part (if present) ... };

  # Now get the text part of the message
  my $MT = $IMAP->fetch(1, 'body[' . $MC->{plain}->{'IMAP-Part'} . ']');

=cut
sub find_message {
  my @ComponentList = @_;
  my (%MsgComponents, $Found);

  my @TextParts = qw(plain text enriched calendar);

  # Repeat until we find something
  while (@ComponentList) {
    my $CurrentComponent = shift @ComponentList;

    # Yay, found text component
    my $CD = $CurrentComponent->{'Content-Disposition'};
    if ($CurrentComponent->{'MIME-Type'} eq 'text') {

      # Skip it attachment or inline which has a filename
      next if ref($CD) && $CD->{attachment};
      next if ref($CD) && $CD->{inline}->{filename};

      # See if it's a sub-type we understand/want
      my $SubType = $CurrentComponent->{'MIME-Subtype'};
      if (grep { $SubType eq $_ } @TextParts, 'html') {

        # Found it if not already found one of this type
        if (!exists $MsgComponents{$SubType}) {
          $MsgComponents{$SubType} = $CurrentComponent;

        # Override existing part if old part is 0 size, and new part is >0 size
        } elsif ($MsgComponents{$SubType}->{'Size'} == 0 &&
                 $CurrentComponent->{'Size'} > 0) {
          $MsgComponents{$SubType} = $CurrentComponent;
        }
      }
    }

    # If it's a multi-part, what type
    if ($CurrentComponent->{'MIME-Type'} eq 'multipart') {

      # Look at all sub-parts that aren't messages themselves
      my @MultiComponents =
        grep { $_->{'MIME-Type'} ne 'message' }
          @{$CurrentComponent->{'MIME-Subparts'}};

      # If it's a signed/alternative sub-part, look in it FIRST
      if ($CurrentComponent->{'MIME-Subtype'} eq 'signed' ||
          $CurrentComponent->{'MIME-Subtype'} eq 'alternative') {
        unshift @ComponentList, @MultiComponents;

      # Otherwise look in it after we've looked at all the other components
      #  at the current level
      } else {
        push @ComponentList, @MultiComponents;
      }
    }
  }

  # we don't want to return multiple text parts!
  my @TextParts1 = @TextParts;
  while (my $SubType = shift @TextParts1) {
    if (exists $MsgComponents{$SubType}) {
      for (@TextParts1) { delete $MsgComponents{$_}; }
      last;
    }
  }

  return \%MsgComponents;
}

=item I<build_cid_map($BodyStruct)>

This is a helper function that can be used to further parse the
results of a fetched bodystructure. It recursively parses the
bodystructure and returns a hash of Content-ID to bodystruct
part references. This is useful when trying to determine CID
links from an HTML message.

Examples:

  # Fetch body structure
  my $FR = $IMAP->fetch(1, 'bodystructure');
  my $BS = $FR->{1}->{bodystructure};

  # Parse further to get CID links
  my $CL = $IMAP->build_cid_map($BS);
  $CL = { '2958293123' => ... ref to body part ..., ... };

=cut
sub build_cid_map {
  my @PartStack = @_;
  my %CIDHash;

  # While items left to process
  while (my $Part = shift @PartStack) {

    # For multi-part types, just add sub-parts to process stack
    if ($Part->{'MIME-Type'} eq 'multipart') {
      push @PartStack, @{$Part->{'MIME-Subparts'}};
    }

    # If content-id present
    if (my $CID = $Part->{'Content-ID'}) {
      # Strip any <> parts and add to hash
      $CID =~ s/^<(.*)>$/$1/;
      $CIDHash{$CID} = $Part
    }
  }

  return \%CIDHash;
}

=back
=cut

=head1 FETCH RESULTS

The 'fetch' operation is probably the most common thing you'll do with an
IMAP connection. This operation allows you to retrieve information about a
message or set of messages, including header fields, flags or parts of the
message body.

C<Mail::IMAPTalk> will always parse the results of a fetch call into a Perl like
structure, though 'bodystructure', 'envelope' and 'uid' responses may
have additional parsing depending on the C<parse_mode> state and the C<uid>
state (see below).

For an example case, consider the following IMAP commands and responses
(C is what the client sends, S is the server response).

  C: a100 fetch 5,6 (flags rfc822.size uid)
  S: * 1 fetch (UID 1952 FLAGS (\recent \seen) RFC822.SIZE 1150)
  S: * 2 fetch (UID 1958 FLAGS (\recent) RFC822.SIZE 110)
  S: a100 OK Completed

The fetch command can be sent by calling:

  my $Res = $IMAP->fetch('1:*', '(flags rfc822.size uid)');

The result in response will look like this:

  $Res = {
    1 => {
      'uid' => 1952,
      'flags' => [ '\\recent', '\\seen' ],
      'rfc822.size' => 1150
    },
    2 => {
      'uid' => 1958,
      'flags' => [ '\\recent' ],
      'rfc822.size' => 110
    }
  };


A couple of points to note:

=over 

=item 1.

The message IDs have been turned into a hash from message ID to fetch
response result.

=item 2.

The response items (e.g. uid, flags, etc) have been turned into a hash for
each message, and also changed to lower case values.

=item 3.

Other bracketed (...) lists have become array references.

=back

In general, this is how all fetch responses are parsed when the C<parse_mode>
is set to 0. There is one major difference however when the IMAP connection
is in 'uid' mode. In this case, the message IDs in the main hash are changed
to message UIDs, and the 'uid' entry in the inner hash is removed. So the
above example would become:

  my $Res = $IMAP->fetch('1:*', '(flags rfc822.size)');

  $Res = {
    1952 => {
      'flags' => [ '\\recent', '\\seen' ],
      'rfc822.size' => 1150
    },
    1958 => {
      'flags' => [ '\\recent' ],
      'rfc822.size' => 110
    }
  };

=head2 Bodystructure

When dealing with messages, we need to understand the MIME structure of
the message, so we can work out what is the text body, what is attachments,
etc. This is where the 'bodystructure' item from an IMAP server comes in.

  C: a101 fetch 1 (bodystructure)
  S: * 1 fetch (BODYSTRUCTURE ("TEXT" "PLAIN" NIL NIL NIL "QUOTED-PRINTABLE" 255 11 NIL ("INLINE" NIL) NIL))
  S: a101 OK Completed

The fetch command can be sent by calling:

  my $Res = $IMAP->fetch(1, 'bodystructure');

As expected, the resultant response would look like this:

  $Res = {
    1 => {
      'bodystructure' => [
        'TEXT', 'PLAIN', undef, undef, undef, 'QUOTED-PRINTABLE',
          255, 11, UNDEF, [ 'INLINE', undef ], undef
      ]
    }
  };

However, if you set the C<parse_mode> state to 1, then the result would be:

  $Res = {
    '1' => {
      'bodystructure' => {
        'MIME-Type' => 'text',
        'MIME-Subtype' => 'plain',
        'MIME-TxtType' => 'text/plain',
        'Content-Type' => {},
        'Content-ID' => undef,
        'Content-Description' => undef,
        'Content-Transfer-Encoding' => 'QUOTED-PRINTABLE',
        'Size' => '3569',
        'Lines' => '94',
        'Content-MD5' => undef,
        'Content-Disposition' => [
          'INLINE',
          undef
        ],
        'Content-Language' => undef,
        'Remainder' => [],
        'IMAP-Partnum' => ''
      }
    }
  };

A couple of points to note here:

=over 4

=item 1.

All the fields have been turned into nicely named hash items.

=item 2.

The MIME-Type and MIME-Subtype fields have been made lower case.

=item 3.

An IMAP-Partnum item has been added. The value in this field can
be passed as the 'section' number of an IMAP body fetch call to
retrieve the text of that IMAP section.

=back

In general, the following items are defined for all body structures:

=over 4

=item * MIME-Type

=item * MIME-Subtype

=item * Content-Type

=item * Content-Disposition

=item * Content-Language

=back

For all items EXCEPT those that have a MIME-Type of 'multipart', the
following are defined:

=over 4

=item * Content-ID

=item * Content-Description

=item * Content-Transfer-Encoding

=item * Size

=item * Content-MD5

=item * Remainder

=item * IMAP-Partnum

=back

For items where MIME-Type is 'text', an extra field 'Lines' is defined.

For items where MIME-Type is 'message' and MIME-Subtype is 'rfc822', the
extra fields 'Message-Envelope', 'Message-Bodystructure' and 'Message-Lines'
are defined. The 'Message-Bodystructure' field is itself a hash references
to an entire bodystructure hash with all the format information of the
contained message. The 'Message-Envelope' field is a hash structure with
the message header information. See the B<Envelope> entry below.

For items where MIME-Type is 'multipart', an extra field 'MIME-Subparts' is
defined. The 'MIME-Subparts' field is an array reference, with each item being a
hash reference to an entire bodystructure hash with all the format information
of each MIME sub-part.

For further processing, you can use the B<find_message()> function.
This will analyse the body structure and find which part corresponds
to the main text/html message parts to display. You can also use
the B<find_cid_parts()> function to find CID links in an html
message.

=head2 Envelope

The envelope structure contains most of the addressing header fields from
an email message. The following shows an example envelope fetch (the
response from the IMAP server has been neatened up here)

  C: a102 fetch 1 (envelope)
  S: * 1 FETCH (ENVELOPE
      ("Tue, 7 Nov 2000 08:31:21 UT"      # Date
       "FW: another question"             # Subject
       (("John B" NIL "jb" "abc.com"))    # From
       (("John B" NIL "jb" "abc.com"))    # Sender
       (("John B" NIL "jb" "abc.com"))    # Reply-To
       (("Bob H" NIL "bh" "xyz.com")      # To
        ("K Jones" NIL "kj" "lmn.com"))
       NIL                                # Cc
       NIL                                # Bcc
       NIL                                # In-Reply-To
       NIL)                               # Message-ID
     )
  S: a102 OK Completed

The fetch command can be sent by calling:

  my $Res = $IMAP->fetch(1, 'envelope');

And you get the idea of what the resultant response would be. Again
if you change C<parse_mode> to 1, you get a neat structure as follows:

  $Res = {
    '1' => {
      'envelope' => {
        'Date' => 'Tue, 7 Nov 2000 08:31:21 UT',
        'Subject' => 'FW: another question',
        'From' => '"John B" <jb@abc.com>',
        'Sender' => '"John B" <jb@abc.com>',
        'Reply-To' => '"John B" <jb@abc.com>',
        'To' => '"Bob H" <bh@xyz.com>, "K Jones" <kj@lmn.com>',
        'Cc' => '',
        'Bcc' => '',
        'In-Reply-To' => undef,
        'Message-ID' => undef,

        'From-Raw' => [ [ 'John B', undef, 'jb', 'abc.com' ] ],
        'Sender-Raw' => [ [ 'John B', undef, 'jb', 'abc.com' ] ],
        'Reply-To-Raw' => [ [ 'John B', undef, 'jb', 'abc.com' ] ],
        'To-Raw' => [
          [ 'Bob H', undef, 'bh', 'xyz.com' ],
          [ 'K Jones', undef, 'kj', 'lmn.com' ],
        ],
        'Cc-Raw' => [],
        'Bcc-Raw' => [],
      }
    }
  };

All the fields here are from straight from the email headers.
See RFC822 for more details.

=cut

=head1 INTERNAL METHODS

=over 4
=cut

=item I<_imap_cmd($Command, $IsUidCmd, $RespItems, @Args)>

Executes a standard IMAP command.

=item I<Method arguments>

=over 4

=item B<$Command>

Text string of command to call IMAP server with (e.g. 'select', 'search', etc).

=item B<$IsUidCmd>

1 if command involved message ids and can be prefixed with UID, 0 otherwise.

=item B<$RespItems>

Responses to look for from command (eg 'list', 'fetch', etc). Commands
which return results usually return them untagged. The following is an
example of fetching flags from a number of messages.

  C123 uid fetch 1:* (flags)
  * 1 FETCH (FLAGS (\Seen) UID 1)
  * 2 FETCH (FLAGS (\Seen) UID 2)
  C123 OK Completed

Between the sending of the command and the 'OK Completed' response,
we have to pick up all the untagged 'FETCH' response items so we
would pass 'fetch' (always use lower case) as the $RespItems to extract.

=item B<@Args>

Any extra arguments to pass to command.

=back

=cut
sub _imap_cmd {
  my ($Self, $Cmd, $IsUidCmd, $RespItems, @Args) = @_;

  # Remember the last command and reset last error
  $Self->{LastCmd} = $Cmd;
  $Self->{LastError} = undef;

  # Prefix command with uid if uid command and in uid mode
  $Cmd = 'uid ' . $Cmd if $IsUidCmd && $Self->{Uid};

  # Send command and parse response. Put in an eval because we 'die' if any problems
  my ($CompletionResp, $DataResp);
  eval {
    # Send the command and parse the response
    $Self->_send_cmd($Cmd, @Args);
    # Items returned are the complete response (eg ok/bad/no) and
    #  the any parsed data to return from the command
    ($CompletionResp, $DataResp) = $Self->_parse_response($RespItems);
    $Self->{CmdId}++;
  };
  $Self->{LastRespCode} = $CompletionResp;

  # Return undef if any error occurred (either through 'die' or non-'OK' IMAP response)
  if ($@) { 
    $Self->{LastError} = $@ = "IMAP Command : '$Cmd' failed. Reason was : $@";
    return undef;
  };

  if ($CompletionResp !~ /^ok/) {
    $Self->{LastError} = $@ = "IMAP Command : '$Cmd' failed. Response was : $CompletionResp - $DataResp";
    return undef;
  }

  # If we want an array response, handle undef and array ref cases specially
  if (wantarray) {
    # If undef response, return empty array
    return () if !defined($DataResp);
    # If respose is array reference, return array
    return @$DataResp if ref($DataResp) eq "ARRAY";
  }

  # Otherwise return response as single item
  return $DataResp;
}

=item I<_send_cmd($Self, $Cmd, @InArgs)>

Helper method used by the B<_imap_cmd> method to actually build (and
quote where necessary) the command arguments and then send the
actual command.

=cut
sub _send_cmd {
  my ($Self, $Cmd, @InArgs) = @_;

  # Quote any args as required
  my @OutArgs;
  foreach my $Arg (@InArgs) {
    # If it's a reference, then must be a file or a 'NoQuote' array, keep in arg list
    if (ref($Arg)) {
      push @OutArgs, $Arg;

    # If it's got a \000 or \012 or \015, we need to make it a literal.
    # Do this by making an array reference which we'll look for later
    } elsif ($Arg =~ m/[\000\012\015]/) {
      push @OutArgs, [ 'Literal', $Arg ];

    # If it's got other invalid chars, but doesn't start with a "(",
    # just quote it
    } elsif ($Arg =~ m/[\000-\040\{\} \%\*\"\(\)]/ && !($Arg =~ m/^\(/)) {
      push @OutArgs, _quote($Arg);

    # Empty string, send empty quotes
    } elsif ($Arg =~ m/^$/) {
      push @OutArgs, _quote("");

    # Otherwise leave as normal
    } else {
      push @OutArgs, $Arg;
    }
  }

  # Clear tracing buffer if requested
  ${$Self->{Trace}} = '' if $Self->{ClearEachCmd} && ref($Self->{Trace}) eq 'SCALAR';

  # Send command. Build line buffer of args
  my $LineBuffer = $Self->{CmdId} . " " . $Cmd;
  foreach my $Arg (@OutArgs) { if (defined($Arg)) {
    # If the argument is a reference:
    # * If it's not an array reference, it's a literal
    # * If it's an array reference,
    #   and the first item is 'Literal' then it's a literal
    if (ref($Arg) && (ref($Arg) ne "ARRAY" || 
      (ref($Arg) eq "ARRAY" && $Arg->[0] eq 'Literal'))) {
      # Get the size of the literal
      my $LiteralSize = 0;

      # If it's an array ref, should contain one string
      if (ref($Arg) eq "ARRAY") {
        $LiteralSize = length($Arg->[1]);

      # Otherwise it's a file ref
      } else {
        $Arg->seek(0, 2); # SEEK_END
        $LiteralSize = $Arg->tell();
        $Arg->seek(0, 0); # SEEK_SET
      }

      # Add to line buffer and send
      $LineBuffer .= " {" . $LiteralSize . "}" . LB;
      $Self->_imap_socket_out($LineBuffer);
      $LineBuffer = "";

      # Wait for "+ go ahead" response
      my $GoAhead = $Self->_imap_socket_read_line();
      if ($GoAhead =~ /^\+/) {
        if (ref($Arg) eq "ARRAY") {
          $Self->_imap_socket_out($Arg->[1]);
        } else {
          $Self->_copy_handle_to_handle($Arg, $Self->{Socket}, $LiteralSize);
        }

      # If no "+ go ahead" response, set error state
      } else {
        die 'Did not get "+ ...go ahead..." response from IMAP server. Got - ' . $GoAhead;
      }

    # Otherwise it's just a string, add to line buffer
    } else {
      my $Value = $Arg;
      if (ref($Arg) eq "ARRAY") {
        if ($Arg->[0] eq 'DoQuote') {
          $Value = $Arg->[1];
          $Value = _quote($Value);
        } else {
          $Value = $Arg->[1]; 
        }
      }
      $LineBuffer .= ($LineBuffer ne "" ? " " : "") . $Value;
    }
  } }

  # Output remainder of line buffer (if empty, we still want
  #  to send the \015\012 chars)
	#  warn("Doing command - $LineBuffer");
  $Self->_imap_socket_out($LineBuffer . LB);

  return 1;
}

=item I<_parse_response($Self, $RespItems)>

Helper method called by B<_imap_cmd> after sending the command. This
methods retrieves data from the IMAP socket and parses it into Perl
structures and returns the results.

=cut
sub _parse_response {
  my ($Self, $RespItems) = @_;

  # Loop until we get the tagged response for the sent command
  my $Tag = '';
  # Store completion response and data responses
  my ($DataResp, $CompletionResp, $Res1);
  while ($Tag ne $Self->{CmdId}) {
    # Force starting new line read
    $Self->{ReadLine} = undef;

    # Get next response id and response item type
    $Tag = $Self->_next_atom();
    $Res1 = $CompletionResp = lc($Self->_next_atom());

    # This is a big switch that works out what to do with each result type

    # If it's a number, we're getting some info about a message
    RepeatSwitch:
    if ($Res1 =~ /^(\d+)$/) {

      my $Res2 = lc($Self->_next_atom());
      if ($Res2 eq 'exists' || $Res2 eq 'recent' || $Res2 eq 'expunge') {
        $Self->{Cache}->{$Res2} = $Res1;
      } elsif ($Res2 eq 'fetch') {
        # Handle fetch response
        my $Fetch = _parse_fetch_result($Self->_next_atom(), $Self->{ParseMode});
        # If UID mode, and got fetch result, transform from ID -> UID hash
        $Res1 = $Fetch->{uid} if $Self->{Uid};
        $Res1 ||= '';
        # Store the result in our response hash
        $DataResp = {} if ref($DataResp) ne 'HASH';
        $DataResp->{$Res1} = $Fetch;
      } elsif (!$DataResp) {
        # Don't know other response types, just return the atom
        $DataResp = $Self->_next_atom();
      }

    } elsif ($Res1 eq 'search' || $Res1 eq 'sort') {
      $DataResp = $Self->_remaining_atoms(1);

    } elsif ($Res1 eq 'flags' || $Res1 eq 'status' || $Res1 eq 'capability' ||
             $Res1 eq 'thread' || $Res1 eq 'namespace') {
      $DataResp = $Self->_remaining_atoms();

    } elsif ($Res1 eq 'list' || $Res1 eq 'lsub') {
      my ($Attr, $Sep, $Name) = @{$Self->_remaining_atoms()};
      $Self->_set_separator($Sep);
      # Remove root text from folder name
      my $RFM = $Self->{RootFolderMatch2};
      $Name =~ s/^$RFM// if $RFM;
      $DataResp = [] if ref($DataResp) ne 'ARRAY';
      push @$DataResp, [ $Attr, $Sep, $Name ];

    } elsif ($Res1 eq 'ok') {
      # If OK, probably something like * OK [... ]
      my $Line = $Self->_remaining_line();
      $Res1 = $Line;
      # Extract items inside [...]
      if ($Line =~ /\[(.*)\](.*)$/) {
        $Self->{ReadLine} = $1;
        # Use atom parser to get internal items
        $Res1 = lc($Self->_next_atom());
        goto RepeatSwitch;
      }

    } elsif ($Res1 eq 'permanentflags' || $Res1 eq 'uidvalidity' ||
      $Res1 eq 'uidnext') {
      $Self->{Cache}->{$Res1} = $Self->_next_atom();
      $Self->_remaining_line();

    } elsif ($Res1 eq 'alert' || $Res1 eq 'newname' ||
      $Res1 eq 'parse' || $Res1 eq 'trycreate') {
      $Self->{Cache}->{$Res1} = $Self->_remaining_line();

    } elsif ($Res1 eq 'appenduid') {
      $Self->{Cache}->{$Res1} = [ $Self->_next_atom(), $Self->_next_atom() ];
      $Self->_remaining_line();

    } elsif ($Res1 eq 'copyuid') {
      $Self->{Cache}->{$Res1} = [ $Self->_next_atom(), $Self->_next_atom(), $Self->_next_atom() ];
      $Self->_remaining_line();

    } elsif ($Res1 eq 'read-write' || $Res1 eq 'read-only') {
      $Self->{Cache}->{$Res1} = 1;
      $Self->{Cache}->{foldermode} = $Res1;
      $Self->_remaining_line();

    } elsif ($Res1 eq 'quota') {
      # Result is: foldername (limits triplets)
      # If just a 'getquota', just return triplets. If a 'getrootquota',
      #  build the hash response
      my ($qfolder, $qlimits) = ($Self->_next_atom(), $Self->_next_atom());
      if (ref($DataResp)) {
        $DataResp->{$qfolder} = $qlimits;
      } else {
        $DataResp = $qlimits;
      }

    } elsif ($Res1 eq 'quotaroot') {
      # Result is: foldername rootitems
      $DataResp = { 'quotaroot' => $Self->_remaining_atoms() };

    } elsif ($Res1 eq 'acl') {
      $DataResp = $Self->_remaining_atoms();
      shift @$DataResp;

    } elsif ($Res1 eq 'annotation') {
      my ($Name, $Entry, $Attributes) = @{$Self->_remaining_atoms()};
      my $RFM = $Self->{RootFolderMatch2};
      $Name =~ s/^$RFM// if $RFM;
      $DataResp = {} if ref($DataResp) ne 'HASH';
      $DataResp->{$Name}->{$Entry} = { @{$Attributes || []} };

    } elsif (($Res1 eq 'bye') && ($Self->{LastCmd} ne 'logout')) {
      die "Connection was unexpectedly closed by host";

    } elsif ($Res1 eq 'no') {
      $DataResp = $Self->_remaining_line();

    } else {
      $Res1 = $Self->_remaining_line();
    }

    # Should have read all of line
    if ($Self->{ReadLine} ne '') {
      die 'Unexpected data remaining on response line "' . $Self->{ReadLine} . '"';
    }

  }

  return ($CompletionResp, $DataResp || $Res1);
}

=item I<_require_capability($Self, $Capability)>

Helper method which checks that the server has a certain capability.
If not, it sets the internal last error, $@ and returns undef.

=cut
sub _require_capability {
  my ($Self, $Capability) = @_;
  my $Caps = $Self->capability() || {};
  if (!exists $Caps->{$Capability}) {
    $Self->{LastError} = $@ = "IMAP server has no $Capability capability";
    return undef;
  }
  return 1;
}

=item I<_trace($Self, $Line)>

Helper method which outputs any tracing data.

=cut
sub _trace {
  my ($Self, $Line) = @_;
  $Line =~ s/\015\012/\n/;
  my $Trace = $Self->{Trace};
  
  if (ref($Trace) eq 'GLOB') {
    print $Trace $Line;
  } elsif (ref($Trace) eq 'CODE') {
    $Trace->($Line);
  } elsif (ref($Trace) eq 'SCALAR') {
    $$Trace ||= '';
    $$Trace .= $Line;
  } elsif ($Trace == 1) {
    print STDERR $Line;
  }
}

=item I<_signal($Self, $Type, @Items)>

Send a signal to a callback.

=cut
sub _signal {
  my ($Self, $Type, @Items) = @_;
  my $Sub = $Self->{CallBacks}->{$Type};
  return $Sub ? $Sub->(@Items) : 1;
}

=back
=cut

=head1 INTERNAL SOCKET FUNCTIONS

=over 4
=cut

=item I<_next_atom($Self)>

Returns the next atom from the current line. Uses $Self->{ReadLine} for
line data, or if undef, fills it with a new line of data from the IMAP
connection socket and then begins processing.

If the next atom is:

=over 4

=item *

An unquoted string, simply returns the string.

=item *

A quoted string, unquotes the string, changes any occurances
of \" to " and returns the string.

=item *

A literal (e.g. {NBytes}\r\n), reads the number of bytes of data
in the literal into a scalar or file (depending on C<literal_handle_control>).

=item *

A bracketed structure, reads all the sub-atoms within the structure
and returns an array reference with all the sub-atoms.

=back

In each case, after parsing the atom, it removes any trailing space separator,
and then returns the remainder of the line to $Self->{ReadLine} ready for the
next call to C<_next_atom()>.

=cut
sub _next_atom {
  my ($Self, $Atom, $CurAtom, @AtomStack) = (+shift, undef, undef);
  my ($Line, $AtomRef) = ($Self->{ReadLine}, \$Atom);

  # Fill line buffer if nothing left
  $Line = $Self->_imap_socket_read_line() if !defined $Line;

  # While this is a recursive structure, doing some profiling showed
  #  that this call was taking up quite a bit of time in the application
  #  I was using this module with. Thus I've tried to optimise the code
  #  a bit by turning it into a loop with an explicit stack and keeping
  #  the most common cases quick.

  # Always do this once, and keep doing it while we're within
  #   a bracketed list of items
  do {

    # Single item? (and any trailing space)
    if ($Line =~ m/\G([^()\"{}\s]+) ?/gc) {
      # Add to current atom. If there's a stack, must be within a bracket
      if (scalar @AtomStack) {
        push @$AtomRef, $1 eq 'NIL' ? undef : $1;
      } else {
        $$AtomRef = $1 eq 'NIL' ? undef : $1;
      }
    }

    # Quoted section? (but non \" end quote and any trailing space)
    elsif ($Line =~ m/\G"((?:\\.|[^"])*?)" ?/gc) {
      # Unquote quoted items
      ($CurAtom = $1) =~ s/\\(.)/$1/g;
      # Add to current atom. If there's a stack, must be within a bracket
      if (scalar @AtomStack) {
        push @$AtomRef, $CurAtom;
      } else {
        $$AtomRef = $CurAtom;
      }
    }
    
    # Bracket?
    elsif ($Line =~ m/\G\(/gc) {
      # Begin a new sub-array
      my $CurAtom = [];
      # Add to current atom. If there's a stack, must be within a bracket
      if (scalar @AtomStack) {
        push @$AtomRef, $CurAtom;
      } else {
        $$AtomRef = $CurAtom;
      }
      # Add current ref to stack and update
      push @AtomStack, $AtomRef;
      $AtomRef = $CurAtom;
    }

    # End bracket? (and possible trailing space)
    elsif ($Line =~ m/\G\) ?/gc) {
      # Close existing sub-array
      if (!scalar @AtomStack) {
        die "Unexpected close bracket in IMAP response : '$Line'";
      }
      $AtomRef = pop @AtomStack;
    }

    # Literal? (Must end line)
    elsif ($Line =~ m/\G\{(\d+)\}$/gc) {
      if ($CurAtom = $Self->{LiteralControl}) {
        $Self->_copy_imap_socket_to_handle($CurAtom, $1);
      } else {
        # Capture with regexp to untaint
        my $Bytes = $Self->_imap_socket_read_bytes($1);
        ($CurAtom) = ($Bytes =~ /^(.*)$/s);
      }
      # Read new line and strip first space if any
      $Line = $Self->_imap_socket_read_line();
      $Line =~ s/^ //;
      # Add to current atom. If there's a stack, must be within a bracket
      if (scalar @AtomStack) {
        push @$AtomRef, $CurAtom;
      } else {
        $$AtomRef = $CurAtom;
      }
    }

    # End of line?
    elsif ($Line =~ m/\G$/gc) {
      # Should not be within brackets
      if (scalar @AtomStack) {
        die "Unexpected end of line in IMAP response : '".$Self->{ReadLine}."'";
      }
      # Otherwise fine, we're about to exit anyway
    }

    else {
      die "Error parsing atom in IMAP response : '$Line'";
    }

  # Repeat while we're within brackets
  } while (scalar @AtomStack);

  # Return rest of line to read line buffer
  $Self->{ReadLine} = substr($Line, pos($Line));

  return $Atom;
}

=item I<_remaining_atoms($Self)>

Returns all the remaining atoms for the current line in the read line
buffer as an array reference. Leaves $Self->{ReadLine} eq ''.
See C<_next_atom()>

=cut
sub _remaining_atoms() {
  my ($Self, $SlurpIDs) = @_;

  my @AtomList;

  # A hack. 'search' and 'sort' commands return a ID/UID list to end-of-line.
  #  Use a quick loop to pull these out one at a time and cast to int() which
  #  reduces memory usage, and is faster than general _next_atom() calls
  if ($SlurpIDs) {
    for ($Self->{ReadLine}) {
      # For really long lines, the while loop below causes perl to bounce
      #  mmap/munmap calls, causing it to be really slow. Use an even
      #  hackier alternative
      if (length $_ > 300000) {

        my @List;
        while (defined $_) {
          # We split into 500 items at a time
          (@List[0 .. 498], $_) = split(' ', $_, 500);
          push @AtomList, map { defined $_ ? int($_) : () } @List;
        }
      } else {
        while (/\G(\d+) ?/gc) {
          push @AtomList, int($1);
        }
      }
    }
    $Self->{ReadLine} = '';
    return \@AtomList;
  }

  # Pull all atoms until no line left
  while ($Self->{ReadLine} ne '') {
    push @AtomList, $Self->_next_atom();
  }

  return \@AtomList;
}

=item I<_remaining_line($Self)>

Returns the remaining data in the read line buffer ($Self->{ReadLine}) as
a scalar string/data value.

=cut
sub _remaining_line {
  my $Line = $_[0]->{ReadLine};
  $_[0]->{ReadLine} = '';
  return $Line;
}

=item I<_fill_imap_read_buffer($Self)>

Wait until data is available on the IMAP connection socket (or a timeout
occurs). Read the data into the internal buffer $Self->{ReadBuf}. You
can then use C<_imap_socket_read_line()>, C<_imap_socket_read_bytes()>
or C<_copy_imap_socket_to_handle()> to read data from the buffer in
lines or bytes at a time.

=cut
sub _fill_imap_read_buffer {
  my $Self = shift;
  my $Buffer = '';
  my $Timeout = defined($_[0]) ? +shift : $Self->{Timeout};

  # Nothing to do if buffer already has data.
  # Actually, we want to check the read if timeout is 0
  return 1 if $Self->{ReadBuf} && (!defined $Timeout || $Timeout != 0);

  # Wait for data to become available
  my @ReadList = $Self->{Select}->can_read( $Timeout );

  # If no handles, then timedout
  if (scalar(@ReadList) == 0) {
    die "Read timed out on socket";
  }

  # Check assumption...
  if ($ReadList[0] != $Self->{Socket}) {
    die "Read handles don't match. Internal error";
  }

  # Now read data into read buffer
  my $IsBlocking = $Self->{Socket}->blocking();
  $Self->{Socket}->blocking(0);
  $Self->{Socket}->sysread($Buffer, 16384);
  $Self->{Socket}->blocking($IsBlocking);
  CORE::select(undef, undef, undef, 0.25) if $Self->{go_slow};

  # The select told us there was data, if there wasn't
  # any, it means the other end closed the connection
  if (length($Buffer) == 0) {
    $Self->state(Unconnected);
    die "IMAP Connection closed by other end";
  }

  # Store in read buffer
  $Self->{ReadBuf} .= $Buffer;

  return 1;
}

=item I<_imap_socket_read_line($Self)>

Read a \r\n terminated list from the buffered IMAP connection socket.

=cut
sub _imap_socket_read_line {
  my $Self = shift;
  my $Line = '';

  while (1) {
    # Fill buffer
    $Self->_fill_imap_read_buffer();

    # Add buffer to line
    $Line .= $Self->{ReadBuf};
    $Self->{ReadBuf} = '';

    # Got end of line chars?
    if ((my $LineLen = index($Line, LB)) != -1) {
      # Put remainder into read buffer
      $Self->{ReadBuf} = substr($Line, $LineLen + length(LB));
      # Get line part (minus CR/LF)
      $Line = substr($Line, 0, $LineLen);
      # Do tracing
      $Self->_trace("S: " . $Line . "\n") if $Self->{Trace};
      # And return it
      return $Line;
    }
  }
  return 1;
}

=item I<_imap_socket_read_bytes($Self, $NBytes)>

Read a certain number of bytes from the buffered IMAP connection socket.

=cut
sub _imap_socket_read_bytes {
  my ($Self, $Bytes) = @_;
  my $Buf = '';

  while (length($Buf) < $Bytes) {
    my $NWant = $Bytes - length($Buf);

    # Fill read buffer
    $Self->_fill_imap_read_buffer();

    # More data in read buffer than we need?
    if (length($Self->{ReadBuf}) > $NWant) {
      # Add part to our output buffer
      $Buf .= substr($Self->{ReadBuf}, 0, $NWant);
      # Subtract from read buffer
      $Self->{ReadBuf} = substr($Self->{ReadBuf}, $NWant);
      # Return our output buffer
      return $Buf;
    }

    # Otherwise just add read buffer to out buffer
    $Buf .= $Self->{ReadBuf};
    $Self->{ReadBuf} = '';
  }
  return $Buf;
}

=item I<_imap_socket_out($Self, $Data)>

Write the data in $Data to the IMAP connection socket.

=cut
sub _imap_socket_out {
  my ($Self, $Data) = @_;

  # Do tracing
  $Self->_trace("C: " . $Data) if $Self->{Trace};

  # Keep track of bytes written and total number to write
  my ($WCount, $TCount) = (0, length($Data));

  # Loop to write out all the data if needs multiple passes
  while ($TCount != $WCount) {
    my $NWrite = $Self->{Socket}->syswrite($Data, $TCount - $WCount, $WCount);
    if (!defined $NWrite) {
      # A bit hacky, but try and avoid exposing password
      $Data =~ s/^(\d+ login \S+ )("(?:\\.|[^"])*?"|[^"\s]*)/$1 . ("*" x length($2))/e;
      my $TryData = substr($Data, $WCount, $TCount - $WCount);
      die 'Error writing data "' . Dumper($TryData) . '" to socket.';
    }
    $WCount += $NWrite;
  }
  return 1;
}

=item I<_copy_handle_to_handle($Self, $InHandle $OutHandle, $NBytes)>

Copy a given number of bytes from one handle to another.

The number of bytes specified ($NBytes) must be available on the IMAP socket,
otherwise the function will 'die' with an error if it runs out of data.

If $NBytes is not specified (undef), the function will attempt to
seek to the end of the file to find the size of the file.
 
=cut
sub _copy_handle_to_handle {
  my ($Self, $InHandle, $OutHandle, $NBytes) = @_;

  # If NBytes undef, seek to end to find total length
  if (!defined $NBytes) {
    $InHandle->seek(0, 2); # SEEK_END
    $NBytes = $InHandle->tell();
    $InHandle->seek(0, 0); # SEEK_SET
  }

  # Loop over in handle reading chunks at a time and writing to the out handle
  my $Val;
  while (my $NRead = $InHandle->read($Val, 8192)) {
    if (!defined $NRead) {
      die 'Error reading data from io handle.' . $@;
    }

    my $NWritten = 0;
    while ($NWritten != $NRead) {
      my $NWrite = $OutHandle->syswrite($Val, $NRead-$NWritten, $NWritten);
      if (!defined $NWrite) {
        die 'Error writing data to io handle.' . $@;
      }
      $NWritten += $NWrite;
    }
  }

  # Done
  return 1;
}

=item I<_copy_imap_socket_to_handle($Self, $OutHandle, $NBytes)>

Copies data from the IMAP socket to a file handle. This is different
to _copy_handle_to_handle() because we internally buffer the IMAP
socket so we can't just use it to copy from the socket handle, we
have to copy the contents of our buffer first.

The number of bytes specified must be available on the IMAP socket,
if the function runs out of data it will 'die' with an error.
 
=cut
sub _copy_imap_socket_to_handle {
  my ($Self, $OutHandle, $NBytes) = @_;

  # Loop over socket reading chunks at a time and writing to the out handle
  my $Val;
  while ($NBytes) {
    my $NToRead = ($NBytes > 16384 ? 16384 : $NBytes);
    $Val = $Self->_imap_socket_read_bytes($NToRead);
    my $NRead = length($Val);
    if (length($Val) == 0) {
      die 'Error reading data from socket.' . $@;
    }
    $NBytes -= $NRead;

    my $NWritten = 0;
    while ($NWritten != $NRead) {
      my $NWrite = syswrite($OutHandle,$Val, $NRead-$NWritten, $NWritten);
      if (!defined $NWrite) {
        die 'Error writing data to io handle.' . $@;
      }
      $NWritten += $NWrite;
    }
  }

  # Done
  return 1;
}
  
=item I<_quote($String)>

Returns an IMAP quoted version of a string. This place "..." around the
string, and replaces any internal " with \".
 
=cut
sub _quote {
  # Replace " and \ with \" and \\ and surround with "..."
  my $Str = shift;
  $Str =~ s/(["\\])/\\$1/g;
  return '"' . $Str . '"';
}

=item I<_quote_list(@Items)>

For each item in @Items:
1. If it's a string, quote as "..."
2. If it's an array ref, place in (...) and quote each item.

Returns a list as long as @Items.

=cut
sub _quote_list {
  my @Items = @_;
  for (@Items) {
    if (ref $_) {
      $_ = '(' . join(' ', map { $_->[1] } _quote_list(@$_)) . ')';
    } else {
      # Replace " and \ with \" and \\ and surround with "..."
      s/(["\\])/\\$1/g;
      $_ = [ 'NoQuote', '"' . $_ . '"' ];
    }
  }

  return @Items;
}

=back
=cut

=head1 INTERNAL PARSING FUNCTIONS

=over 4
=cut

=item I<_parse_list_to_hash($ListRef, $Recursive)>

Parses an array reference list of ($Key, $Value) pairs into a hash.
Makes sure that all the keys are lower cased (lc) first.

=cut
sub _parse_list_to_hash {
  my $ContentHashList = shift || [];
  my $Recursive = shift;

  ref($ContentHashList) eq 'ARRAY' || return { };

  my %Res;
  while (@$ContentHashList) {
    my ($Param, $Val) = (shift @$ContentHashList, shift @$ContentHashList);

    $Val = _parse_list_to_hash($Val, $Recursive-1)
      if (ref($Val) && $Recursive);

    $Res{lc($Param)} = $Val;
  }

  return \%Res;
}

=item I<_fix_folder_name($FolderName, $WildCard)>

Changes a folder name based on the current root folder prefix as set
with the C<set_root_prefix()> call.

If $WildCard is true, then a folder name with % or *
is left alone.

=cut
sub _fix_folder_name {
  my ($Self, $FolderName, $WildCard) = @_;

  return $FolderName if $WildCard && $FolderName =~ /[\*\%]/;

  my $RootFolderMatch = $Self->{RootFolderMatch};

  # If no root folder, just return passed in folder
  return $FolderName if !defined($RootFolderMatch);

  # If a matching function, see if it matches
  if ($RootFolderMatch) {
    return $FolderName if $FolderName =~ $RootFolderMatch;
  }

  my ($RootFolder, $Separator) = @$Self{'RootFolder', 'Separator'};
  return !$RootFolder ? $FolderName : $RootFolder . $Separator . $FolderName;
}

=item I<_fix_message_ids($MessageIds)>

Used by IMAP commands to handle a number of different ways that message
IDs can be specified.

=item I<Method arguments>

=over 4

=item B<$MessageIds>

String or array ref which specified the message IDs or UIDs.

=back

The $MessageIds parameter may take the following forms:

=over 4

=item B<array ref>

Array is turned into a string of comma separated ID numbers.

=item B<1:*>

Normally a * would result in the message ID string being quoted.
This ensure that such a range string is not quoted because some
servers (e.g. cyrus) don't like.

=back

=cut
sub _fix_message_ids {
  my $Item = shift;
  # If the item is an array reference, turn into a comma separated of items
  $Item = join(",", @$Item) if ref($Item) eq 'ARRAY' && $Item->[0] ne 'NoQuote';
  # If the item ends in a *, don't put "'s around it. This is
  # a hack so "1:*" doesn't end up with quotes that cyrus doesn't like
  $Item = [ 'NoQuote', $Item ] if $Item =~ /\*$/;
  return $Item;
}

=item I<_parse_email_address($EmailAddressList)>

Converts a list of IMAP email address structures as parsed and returned
from an IMAP fetch (envelope) call into a single RFC822 email string
(e.g. "Person 1 Name" <ename@ecorp.com>, "Person 2 Name" <...>, etc) to
finally return to the user.

This is used to parse an envelope structure returned from a fetch call.
  
See the documentation section 'FETCH RESULTS' for more information.

=cut
sub _parse_email_address {
  my $EmailAddressList = shift || [];
  my $DecodeUTF8 = shift;

  # Email addresses always come as a list of addresses
  my @EmailAdrs;
  foreach my $Adr (@$EmailAddressList) {

    # Check address assumption
    scalar(@$Adr) == 4
      || die "Wrong number of fields in email address structure " . Dumper($Adr);

    # Build 'ename@ecorp.com' part
    my $EmailStr = ($Adr->[2] || '') . '@' . ($Adr->[3] || '');
    # If the email address has a name, add it at the start and put <> around address
    if ($Adr->[0]) {
      _decode_utf8($Adr->[0]) if $DecodeUTF8 && $Adr->[0] =~ $NeedDecodeUTF8Regexp;
      # Strip any existing \"'s
      $Adr->[0] =~ s/\"//g;
      $EmailStr = '"' . $Adr->[0] . '" <' . $EmailStr . '>';
    }

    push @EmailAdrs, $EmailStr;
  }

  # Join the results with commas between each address
  return join(", ", @EmailAdrs);
}

=item I<_parse_envelope($Envelope, $IncludeRaw, $DecodeUTF8)>

Converts an IMAP envelope structure as parsed and returned from an
IMAP fetch (envelope) call into a convenient hash structure.

If $IncludeRaw is true, includes the XXX-Raw fields, otherwise
these are left out.

If $DecodeUTF8 is true, then checks if the fields contain
any quoted-printable chars, and decodes them to a Perl UTF8
string if they do.

See the documentation section 'FETCH RESULTS' from more information.

=cut
sub _parse_envelope {
  my ($Env, $IncludeRaw, $DecodeUTF8) = @_;

  # Check envelope assumption
  scalar(@$Env) == 10
    || die "Wrong number of fields in envelope structure " . Dumper($Env);

  _decode_utf8($Env->[1]) if $DecodeUTF8 && $Env->[1] =~ $NeedDecodeUTF8Regexp;

  # Setup hash directly from envelope structure
  my %Res = (
    'Date',        $Env->[0],
    'Subject',     $Env->[1],
    'From',        _parse_email_address($Env->[2], $DecodeUTF8),
    'Sender',      _parse_email_address($Env->[3], $DecodeUTF8),
    'Reply-To',    _parse_email_address($Env->[4], $DecodeUTF8),
    'To',          _parse_email_address($Env->[5], $DecodeUTF8),
    'Cc',          _parse_email_address($Env->[6], $DecodeUTF8),
    'Bcc',         _parse_email_address($Env->[7], $DecodeUTF8),
    ($IncludeRaw ? (
      'From-Raw',    $Env->[2],
      'Sender-Raw',  $Env->[3],
      'Reply-To-Raw',$Env->[4],
      'To-Raw',      $Env->[5],
      'Cc-Raw',      $Env->[6],
      'Bcc-Raw',     $Env->[7],
    ) : ()),
    'In-Reply-To', $Env->[8],
    'Message-ID',  $Env->[9]
  );

  return \%Res;
}

=item I<_parse_bodystructure($BodyStructure, $IncludeRaw, $DecodeUTF8, $PartNum)>

Parses a standard IMAP body structure and turns it into a Perl friendly
nested hash structure. This routine is recursive and you should not
pass a value for $PartNum when called for the top level bodystructure
item.  Note that this routine destroys the array reference structure
passed in as $BodyStructure.

See the documentation section 'FETCH RESULTS' from more information

=cut
sub _parse_bodystructure {
  my ($Bs, $IncludeRaw, $DecodeUTF8, $PartNum, $IsMultipart) = @_;
  my %Res;

  # If the first item is a reference, then it's a MIME multipart structure
  if (ref($Bs->[0])) {

    # Multipart items are of the form: [ part 1 ] [ part 2 ] ...
    #  "MIME-Subtype" "Content-Type" "Content-Disposition" "Content-Language"

    # Process each mime sub-part recursively
    my ($Part, @SubParts);
    for ($Part = 1; ref($Bs->[0]); $Part++) {
      my $SubPartNum = ($PartNum ? $PartNum . "." : "") . $Part;
      my $Res = _parse_bodystructure(shift(@$Bs), $IncludeRaw, $DecodeUTF8, $SubPartNum, 1);
      push @SubParts, $Res;
    }

    # Setup multi-part hash
    %Res = (
      'MIME-Subparts',       \@SubParts,
      'MIME-Type',           'multipart',
      'MIME-Subtype',        lc(shift(@$Bs)),
      'Content-Type',        _parse_list_to_hash(shift(@$Bs)),
      'Content-Disposition', _parse_list_to_hash(shift(@$Bs), 1),
      'Content-Language',    shift(@$Bs),
      # Shouldn't be anything after this. Add as remainder if there is
      'Remainder',           $Bs
    );
  }

  # Otherwise it's a normal MIME entity
  else {

    # Get the mime type and sub-type
    my ($MimeType, $MimeSubtype) = (lc(shift(@$Bs)), lc(shift(@$Bs)));

    # Partnum for getting the text part of an entity. Do this
    #  here so recursive call works for any embedded messages
    $PartNum = $PartNum ? $PartNum . '.1' : '1'
      if !$IsMultipart;

    # Pull out special fields for 'text' or 'message/rfc822' types
    if ($MimeType eq 'text') {
      %Res = (
        'Lines',   splice(@$Bs, 5, 1)
      );
    } elsif ($MimeType eq 'message' && $MimeSubtype eq 'rfc822') {

      # message/rfc822 includes the messages envelope and bodystructure
      my @MsgParts = splice(@$Bs, 5, 3);
      %Res = (
        'Message-Envelope',       _parse_envelope(shift(@MsgParts), $IncludeRaw, $DecodeUTF8),
        'Message-Bodystructure',  _parse_bodystructure(shift(@MsgParts), $IncludeRaw, $DecodeUTF8, $PartNum),
        'Message-Lines',          shift(@MsgParts)
      );
    }

    # All normal mime-entities have these parts
    %Res = (
      %Res,
      'MIME-Type',                  $MimeType,
      'MIME-Subtype',               $MimeSubtype,
      'Content-Type',               _parse_list_to_hash(shift(@$Bs)),
      'Content-ID',                 shift(@$Bs),
      'Content-Description',        shift(@$Bs),
      'Content-Transfer-Encoding',  shift(@$Bs),
      'Size',                       shift(@$Bs),
      'Content-MD5',                shift(@$Bs),
      'Content-Disposition',        _parse_list_to_hash(shift(@$Bs), 1),
      'Content-Language',           shift(@$Bs),
      # Shouldn't be anything after this. Add as remainder if there is
      'Remainder',                  $Bs
    );

  }

  # Finally set the IMAP body part number and overall mime type
  $Res{'IMAP-Partnum'} = $PartNum || '';
  $Res{'MIME-TxtType'} = $Res{'MIME-Type'} . '/' . $Res{'MIME-Subtype'};

  return \%Res;
}

=item I<_parse_fetch_result($FetchResult)>

Takes the result from a single IMAP fetch response line and parses it
into a Perl friendly structure. 

See the documentation section 'FETCH RESULTS' from more information.

=cut
sub _parse_fetch_result {
  my ($FetchResult, $ParseMode) = @_;

  # Loop over fetch results
  my %ResultHash;
  while (@$FetchResult) {
    # Fetch results are in type, value pairs
    my $Type = lc(shift(@$FetchResult));
    my $Value = shift(@$FetchResult);

    # Process known fetch results into perl form
    if ($Type eq 'envelope') {
      $Value = _parse_envelope($Value, @$ParseMode{qw(EnvelopeRaw DecodeUTF8)})
        if $ParseMode->{Envelope};
    } elsif ($Type eq 'bodystructure') {
      $Value = _parse_bodystructure($Value, @$ParseMode{qw(EnvelopeRaw DecodeUTF8)})
        if $ParseMode->{BodyStructure};
    } elsif ($Type =~ /^(body|binary)(?:\.peek)?\[(.*)/) {
      my $BodyArgs = $2;

      # Make 'body[]', 'body[]<0>', etc into plain 'body'
      $Type = $1;

      if ($BodyArgs =~ /^[\d.]*header/) {
        _parse_header_result($ResultHash{headers} ||= {}, $Value, $FetchResult);
      }
    }

    # Store result (either modified or original) into hash
    $ResultHash{$Type} = $Value;
  }

  return \%ResultHash;
}

=item I<_parse_header_result($HeaderResults, $Value, $FetchResult)>

Take a body[header.fields (xyz)] fetch response and parse out the
header fields and values

=cut
sub _parse_header_result {
  my ($HeaderResults, $Value, $FetchResult) = @_;

  # This is the response for requested headers
  # We don't care HOW they are requested, we just return what we've got
  # from the server, the result is returned in the key "headers"
  $Value = (splice(@$FetchResult,0,2))[1] if (ref($Value) eq 'ARRAY');

  my @HeaderLines = split(/[\r\n]+/,$Value);

  my $PrevHeader;
  for (@HeaderLines) {
    if (/^[\t ]+/){
      next unless $PrevHeader;
      # A continuation line belongs to the last element of the array
      $HeaderResults->{$PrevHeader}[-1] .= "\r\n" . $_;
      next;
    }
    next unless /^([\x21-\x39\x3b-\x7e]+):\s*(.*)$/;
    $PrevHeader = lc($1);
    push @{$HeaderResults->{$PrevHeader}}, $2;
  }
}

=item I<_decode_utf8($Value)>

Decodes the passed quoted printable value to a Perl UTF8 string.

=cut
sub _decode_utf8 {
  eval { $_[0] = decode('MIME-Header', $_[0]); };
}

=back
=cut

=head1 PERL METHODS

=over 4
=cut

=item I<DESTROY()>

Called by Perl when this object is destroyed. Logs out of the
IMAP server if still connected.

=cut
sub DESTROY {
  my $e = $@;  # Save errors from code calling us
  eval {

  my $Self = shift;

  # If socket exists, and connection is open and authenticated or
  #   selected, do a logout
  if ($Self->{Socket} && 
        ($Self->state() == Authenticated || $Self->state() == Selected) &&
        $Self->is_open()) {
    $Self->logout();
    $Self->{Socket}->close();
  }

  };
  # $e .= "        (in cleanup) $@" if $@;
  $@ = $e;
}

=back
=cut

=head1 SEE ALSO

I<Net::IMAP>, I<Mail::IMAPClient>, I<IMAP::Admin>, RFC2060

Latest news/details can also be found at:

http://cpan.robm.fastmail.fm/mailimaptalk/

=cut

=head1 AUTHOR

Rob Mueller E<lt>cpan@robm.fastmail.fmE<gt>. Thanks to Jeremy Howard
E<lt>j+daemonize@howard.fmE<gt> for socket code, support and
documentation setup.

=cut

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2003-2005 by FastMail IP Partners

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;

