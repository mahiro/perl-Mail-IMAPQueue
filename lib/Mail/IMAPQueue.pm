use 5.008_001;
use strict;
use warnings;

package Mail::IMAPQueue;
our $VERSION = '0.1';

use Scalar::Util qw(blessed);

sub new {
	my $class = shift;
	
	my $self = bless {
		client         => undef,
		buffer         => [],
		index          => 0,
		uidnext        => undef,
		skip_initial   => 0,
		idle_timeout   => 30,
		sleep_on_retry => 30,
		max_retry      => undef,
		@_
	}, $class;
	
	my $imap = $self->{client};
	
	unless (blessed($imap) && $imap->isa('Mail::IMAPClient')) {
		$@ = "Parameter 'client' must be given (Mail::IMAPClient)";
		return undef;
	}
	
	if ($self->{skip_initial}) {
		unless ($imap->IsSelected) {
			$@ = "folder must be selected";
			return undef;
		}
		
		$self->{uidnext} = $imap->uidnext($imap->Folder);
		$self->fetch_messages;
		$self->dequeue_messages if defined $self->peek_message;
	}
	
	return $self;
}

sub is_empty {
	my ($self) = @_;
	return $self->{index} >= @{$self->{buffer}};
}

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

sub peek_message {
	my ($self) = @_;
	return undef if $self->is_empty;
	
	my $index = $self->{index};
	my $buffer = $self->{buffer};
	
	return $buffer->[$index];
}

sub peek_messages {
	my ($self) = @_;
	return undef if $self->is_empty;
	
	my $index = $self->{index};
	my $buffer = $self->{buffer};
	
	my $messages = [@$buffer[$index..$#$buffer]];
	
	return wantarray ? @$messages : $messages;
}

sub ensure_messages {
	my ($self) = @_;
	
	if ($self->is_empty) {
		while (1) {
			$self->fetch_messages or return undef;
			
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

sub ensure_connection {
	my ($self) = @_;
	my $imap = $self->{client};
	
	my $max_retry = $self->{max_retry};
	my $sleep_on_retry = $self->{sleep_on_retry} || 30;
	
	$imap->uidvalidity;
	# try something to see if there has been any disconnection
	
	for (my $i = 0; !$imap->reconnect; $i++) {
		if (defined $max_retry && $i >= $max_retry) {
			$@ = "reconnect failed and retry count exceeded max_retry";
			return undef;
		}
		
		if ($sleep_on_retry) {
			select(undef, undef, undef, $sleep_on_retry);
		}
	}
	
	return $imap->IsSelected;
}

sub attempt_idle {
	my ($self) = @_;
	my $imap = $self->{client};
	my $idle_timeout = $self->{idle_timeout} || 30;
	
	eval {
		my $idle_tag = $imap->idle or die $imap;
		my $idle_data = $imap->idle_data($idle_timeout) or die $imap;
		$imap->done($idle_tag) or die $imap;
	};
	
	if ($@) {
		if (ref $@ && $@ == $imap) {
			$self->ensure_connection() or do {
				$@ = "disconnected while attempting IDLE";
				return undef;
			};
		} else {
			return undef;
		}
	}
	
	return $self;
}

sub fetch_messages {
	my ($self) = @_;
	
	my $uidnext = $self->{uidnext};
	my $buffer = [];
	
	TRY: {
		my $imap = $self->{client};
		
		unless ($imap->IsSelected) {
			$@ = "folder must be selected";
			return undef;
		}
		
		eval {
			# UIDNEXT must be called before SEARCH, where this UIDNEXT will
			# be used in the *next* fetch, not this current fetch.
			# This is how to avoid dropping any messages delivered between
			# invocations of SEARCH and UIDNEXT etc.
			my $next_uidnext = $imap->uidnext($imap->Folder);
			defined $next_uidnext or die $imap;
			
			unless (defined $uidnext) {
				# Initially $uidnext is undef (except it was set explicitly)
				$uidnext = $next_uidnext;
				$buffer = $imap->messages or die $imap;
			} else {
				$buffer = $imap->search("UID $uidnext:*") or die $imap;
				
				# Any messages delivered between the last UIDNEXT and SEARCH
				# should be excluded.
				$buffer = [grep {
					$uidnext <= $_ && $_ < $next_uidnext
				} @$buffer];
				
				if (@$buffer > 0) {
					$uidnext = $next_uidnext;
				}
			}
		};
		
		if ($@) {
			if (ref $@ && $@ == $imap) {
				$self->ensure_connection or return undef;
				redo TRY;
			} else {
				return undef;
			}
		}
	}
	
	if ($buffer) {
		$self->{uidnext} = $uidnext;
		$self->{buffer} = $buffer;
		$self->{index} = 0;
	}
	
	return $self;
}

1;
