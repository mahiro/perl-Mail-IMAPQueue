use 5.008_001;
use strict;
use warnings;

package Mail::IMAPQueue;

=head1 NAME

Mail::IMAPQueue - IMAP client extension to use a mailbox as a queue of messages

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

use List::Util qw(max);
use Scalar::Util qw(blessed);

=head1 SYNOPSIS

=head2 Initialization

    use Mail::IMAPClient;
    use Mail::IMAPQueue;
    
    my $imap = Mail::IMAPClient->new(
        ... # See Mail::IMAPClient documentation
    ) or die $@;
    
    my $queue = Mail::IMAPQueue->new(
        client => $imap
    ) or die $@;
    
=head2 Basic usage
    
    while (defined(my $msg = $queue->dequeue_message())) {
        # Do something with $msg (sequence number or UID)
    }

=head1 DESCRIPTION

This module provides a way to access a mailbox with IMAP protocol,
regarding the mailbox as a FIFO queue so that the client code can
continuously process incoming email messages.

The instance of C<Mail::IMAPQueue> maintains a buffer internally, and loads
the message sequence numbers (of UIDs) as necessary. When there are no
messages in the mailbox while the buffer is empty, it will wait until new
messages are received in the mailbox.

It is assumed that the UID assigned to each message is I<strictly ascending>
as stated in RFC 3501 2.3.1.1. and that the order for any messages to start
appearing in the result of the SEARCH command is always consistent with
the order of UIDs.

It is also assumed that the IMAP server provides the IDLE extension (RFC 2177),
for real-time updates from the server.

=head1 EXAMPLES

=head2 Dumping messages

    while (defined(my $msg = $queue->dequeue_message())) {
        $imap->message_to_file("/tmp/mails/$msg", $msg) or die $@;
        $imap->delete_message($msg) or die $@;
        $imap->expunge() or die $@ if $queue->is_empty;
    }

=head2 Managing messages with each buffer

    while (my $msg_list = $queue->dequeue_messages()) {
        for my $msg (@$msg_list) {
           # Do something with $msg
           $imap->delete_message($msg) or die $@;
        }
        $imap->expunge() or die $@;
    }

=head2 Controlling timing of fetching and waiting

    while ($queue->update_messages()) { # non-blocking
        my $msg_list = $queue->peek_messages or die $@; # non-blocking
        if (@$msg_list) {
            for my $msg (@$msg_list) {
                # Do something with $msg
            }
        } else {
            $queue->attempt_idle or die $@;
                # blocking wait for new messages, up to 30 sec.
        }
    }

=head1 METHODS

=head2 $class->new(client => $imap, ...)

Instanciate a queue object, with the required field C<client> set to a
L<Mail::IMAPClient> object.

    my $queue = Mail::IMAPQueue->new(
        client       => $imap,
        uidnext      => $known_next_uid, # default = undef
        skip_initial => $true_or_false,  # default = 0
        idle_timeout => $seconds,        # default = 30
    ) or die $@;

No IMAP requests are invoked with the C<client> object during the initialization.
The buffer maintained by this object is initially empty.

=over 4

=item * client => $imap

The underlying client object. It is assumed to be an instance of L<Mail::IMAPClient>,
although the type of the object is not enforced.

=item * uidnext => $known_next_uid

If the next message UID (the smallest UID to be used) is known (e.g. from a previous execution),
specify the value here.

=item * skip_initial => $true_or_false

Specify a true value to skip all the messages initially in the mailbox.
If C<uidnext> option is set, this option will be ignored effectively.

=item * idle_timeout => $seconds

Specify the timeout in seconds for the IDLE command (RFC 2177), which allows the IMAP client
to receive updates from the server in real-time.
It does I<not> mean the method call will give up when there are no updates after the timeout,
but it means how frequently it will reset the IDLE command.

=back

=cut

sub new {
	my $class = shift;
	
	my $self = bless {
		client         => undef,
		buffer         => [],
		index          => 0,
		uidnext        => undef,
		skip_initial   => 0,
		idle_timeout   => 30,
		@_
	}, $class;
	
	my $imap = $self->{client};
	
	unless (blessed($imap)) {
		$@ = "Parameter 'client' must be given (Mail::IMAPClient)";
		return undef;
	}
	
	return $self;
}

=head2 $queue->is_empty()

Return 1 if the current buffer is empty, and 0 otherwise.

=cut

sub is_empty {
	my ($self) = @_;
	return $self->{index} >= @{$self->{buffer}};
}

=head2 $queue->dequeue_message()

Dequeue the next message from the mailbox.
If the current buffer is non-empty, the next message will be removed from the buffer and returned.
Otherwise, the call will be blocked until there is at least one message found in the mailbox,
and then the first message will be removed from the buffer and returned.

The method returns the sequence number of the message
(or UID if the C<Uid> option is turned on for the underlying client).
C<undef> is returned if the attempt to load the messages was failed.

=cut

sub dequeue_message {
	my ($self) = @_;
	$self->ensure_messages;
	return undef if $self->is_empty;
	
	my $index = $self->{index};
	my $buffer = $self->{buffer};
	
	my $message = $buffer->[$index];
	$self->{index}++;
	
	return $message;
}

=head2 $queue->dequeue_messages()

Dequeue the next list of messages.
If the current buffer is non-empty, all the messages will be removed from the buffer and returned.
Otherwise, the call will be blocked until there is at least one message found in the mailbox,
and then all the loaded messages will be removed and returned.

In the list context, the method returns an array of the message sequence numbers
(or UIDs if the C<Uid> option is turned on for the underlying client).
In the scalar context, a reference to the array is returned.
C<undef> is returned if the attempt to load the messages was failed.

=cut

sub dequeue_messages {
	my ($self) = @_;
	$self->ensure_messages;
	return undef if $self->is_empty;
	
	my $index = $self->{index};
	my $buffer = $self->{buffer};
	
	my $messages = [@$buffer[$index..$#$buffer]];
	$self->{index} = @$buffer;
	
	return wantarray ? @$messages : $messages;
}

=head2 $queue->peek_message()

Retrieve the first message in the current buffer without removing the message.

The method returns the sequence number of the message
(or UID if the C<Uid> option is turned on for the underlying client).
C<undef> is returned if the current buffer is empty.

=cut

sub peek_message {
	my ($self) = @_;
	return undef if $self->is_empty;
	
	my $index = $self->{index};
	my $buffer = $self->{buffer};
	
	return $buffer->[$index];
}

=head2 $queue->peek_messages()

Retrieve all the messages in the current buffer without removing the messages.

In the list context, the method returns an array of the message sequence numbers
(or UIDs if the C<Uid> option is turned on for the underlying client).
In the scalar context, a reference to the array is returned.

=cut

sub peek_messages {
	my ($self) = @_;
	return [] if $self->is_empty;
	
	my $index = $self->{index};
	my $buffer = $self->{buffer};
	
	my $messages = [@$buffer[$index..$#$buffer]];
	
	return wantarray ? @$messages : $messages;
}

=head2 $queue->ensure_messages()

The call is blocked until there is at least one message loaded into the buffer.

The method returns the object itself if successful, and C<undef> otherwise.

=cut

sub ensure_messages {
	my ($self) = @_;
	
	if ($self->is_empty) {
		while (1) {
			$self->update_messages or return undef;
			
			if ($self->is_empty) {
				$self->attempt_idle() or return undef;
			} else {
				# success
				return $self;
			}
		}
	}
	
	return $self;
}

=head2 $queue->attempt_idle()

Attempt the IDLE command so that the call is blocked until there are any updates in the mailbox
or the timeout (default = 30 sec.) has elapsed.

The method returns the object itself if successful, and C<undef> otherwise.

=cut

sub attempt_idle {
	my ($self) = @_;
	my $imap = $self->{client};
	my $idle_timeout = $self->{idle_timeout} || 30;
	
	eval {
		my $idle_tag = $imap->idle or die $imap;
		
		my $idle_data = $imap->idle_data($idle_timeout);
		# do not die even if this fails; always send DONE anyway
		
		$imap->done($idle_tag) or die $imap;
	};
	
	if ($@) {
		if (ref $@ && $@ == $imap) {
			$imap->reconnect or do {
				$@ = "Disconnected while attempting IDLE";
				return undef;
			};
		} else {
			return undef;
		}
	}
	
	return $self;
}

=head2 $queue->update_messages()

Discard the current buffer, and attempt to load any messages from the mailbox to the buffer.
The call is not blocked (except for the usual socket wait for any server response).

The method returns the object itself if successful, and C<undef> otherwise.

=cut

sub update_messages {
	my ($self) = @_;
	
	my $uidnext = $self->{uidnext};
	my $buffer = [];
	
	TRY: {
		my $imap = $self->{client};
		
		unless ($imap->IsSelected) {
			$@ = "Folder must be selected";
			return undef;
		}
		
		eval {
			my $loaded = 0;
			
			unless (defined $uidnext) {
				# Initially $uidnext is undef (except it was set explicitly)
				if ($self->{skip_initial}) {
					$uidnext = $imap->uidnext($imap->Folder) or die $imap;
					$self->{uidnext} = $uidnext;
				} else {
					$buffer = $imap->messages or die $imap;
					$loaded = 1;
				}
			}
			
			unless ($loaded) {
				$buffer = $imap->search("UID $uidnext:*") or die $imap;
				$buffer = [grep {$uidnext <= $_} @$buffer];
			}
		};
		
		if ($@) {
			if (ref $@ && $@ == $imap) {
				$imap->reconnect or return undef;
				redo TRY;
			} else {
				return undef;
			}
		}
	}
	
	if (@$buffer > 0) {
		$uidnext = max(@$buffer) + 1;
		$self->{uidnext} = $uidnext;
	}
	
	$self->{buffer} = $buffer;
	$self->{index} = 0;
	
	return $self;
}

=head1 AUTHOR

Mahiro Ando, C<< <mahiro at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-mail-imapqueue at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Mail-IMAPQueue>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Mail::IMAPQueue

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Mail-IMAPQueue>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Mail-IMAPQueue>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Mail-IMAPQueue>

=item * Search CPAN

L<http://search.cpan.org/dist/Mail-IMAPQueue/>

=back

=head1 ACKNOWLEDGEMENTS

The initial package was created by L<Module::Sterter> v1.58.

This module utilizes L<Mail::IMAPClient> as a client library interface.

=head1 LICENSE AND COPYRIGHT

Copyright 2012 Mahiro Ando.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; version 2 dated June, 1991 or at your option
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

A copy of the GNU General Public License is available in the source tree;
if not, write to the Free Software Foundation, Inc.,
59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

1; # End of Mail::IMAPQueue
