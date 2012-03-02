#!/usr/bin/perl
use 5.008_001;
use strict;
use warnings;

use Test::More tests => 5;
use File::Basename;

use lib dirname(__FILE__).'/lib';
use Mail::IMAPClient;
use Mail::IMAPQueue;
use Mail::IMAPQueue::TestServer;

my $server = Mail::IMAPQueue::TestServer->new(20000, [1, 2, 3]);

sub run {
	my $callback = shift;
	my $client = $server->connect_client;
	
	my $imap = Mail::IMAPClient->new(
		Socket   => $client,
		User     => 'user',
		Password => 'pass',
		Uid      => 1,
	);
	
	$imap->select('INBOX');
	
	my $queue = Mail::IMAPQueue->new(client => $imap, @_);
	$callback->($queue, $imap);
	
	$imap->close;
	$client->shutdown(2);
	$client->close;
}

sub add_message {
	my ($imap) = @_;
	$imap->append_string($imap->Folder, 'test');
}

subtest simple => sub {
	plan tests => 1;
	
	my $got = [];
	
	run(sub {
		my ($queue, $imap) = @_;
		
		while (defined(my $msg = $queue->dequeue_message)) {
			push @$got, $msg;
			last if $queue->is_empty;
		}
	});
	
	is_deeply($got, [1, 2, 3]);
};

subtest incoming_messages => sub {
	plan tests => 1;
	my $got = [];
	
	run(sub {
		my ($queue, $imap) = @_;
		
		for (my $i = 0; defined(my $msg = $queue->dequeue_message); $i++) {
			push @$got, $msg;
			
			if ($i == 1) {
				add_message($imap) foreach 1..2;
			} elsif ($i == 4) {
				add_message($imap);
			}
			
			last if $i >= 5;
		}
	});
	
	is_deeply($got, [1, 2, 3, 4, 5, 6]);
};

subtest skip_initial => sub {
	plan tests => 7;
	my $got = [];
	
	run(sub {
		my ($queue, $imap) = @_;
		
		for (my $i = 0; $i < 6; $i++) {
			if (defined(my $msg = $queue->peek_message)) {
				ok($i == 1 || $i == 2 || $i == 4 || $i == 5);
				push @$got, $msg;
				$queue->dequeue_message;
			} else {
				ok($i == 0 || $i == 3);
				add_message($imap) foreach 1..2;
				$queue->ensure_messages;
			}
		}
	}, skip_initial => 1);
	
	is_deeply($got, [4, 5, 6, 7]);
};

subtest methods => sub {
	plan tests => 36;
	
	run(sub {
		my ($queue, $imap) = @_;
		
		# Load initial 3 messages
		$queue->ensure_messages;
		
		ok !$queue->is_empty;
		is($queue->peek_message, 1);
		is_deeply(scalar($queue->peek_messages), [1, 2, 3]);
		
		# Dequeue 1 message
		is($queue->dequeue_message, 1);
		
		ok !$queue->is_empty;
		
		$queue->ensure_messages; # no effect
		
		ok !$queue->is_empty;
		is($queue->peek_message, 2);
		is_deeply(scalar($queue->peek_messages), [2, 3]);
		
		# Dequeue all the rest
		is_deeply(scalar($queue->dequeue_messages), [2, 3]);
		
		ok $queue->is_empty; # now the buffer is empty
		is($queue->peek_message, undef);
		is_deeply(scalar($queue->peek_messages), []);
		
		# Add three new messages to the server (but no changes in the client)
		add_message($imap) foreach 1..3;
		
		ok $queue->is_empty; # still empty (expected)
		is($queue->peek_message, undef);
		is_deeply(scalar($queue->peek_messages), []);
		
		# Load the added messages
		$queue->ensure_messages;
		
		ok !$queue->is_empty;
		is($queue->peek_message, 4);
		is_deeply(scalar($queue->peek_messages), [4, 5, 6]);
		
		# Dequeue 2 messages
		is($queue->dequeue_message, 4);
		is($queue->dequeue_message, 5);
		
		ok !$queue->is_empty;
		is($queue->peek_message, 6);
		is_deeply(scalar($queue->peek_messages), [6]);
		
		# Add three new messages to the server (but no changes in the client)
		add_message($imap) foreach 1..3;
		
		ok !$queue->is_empty; # still not empty (expected)
		is($queue->peek_message, 6);
		is_deeply(scalar($queue->peek_messages), [6]);
		
		# Discard buffer, and forcefully fetch new messages
		$queue->update_messages;
		
		ok !$queue->is_empty;
		is($queue->peek_message, 7);
		is_deeply(scalar($queue->peek_messages), [7, 8, 9]);
		
		# Dequeue everything
		is_deeply(scalar($queue->dequeue_messages), [7, 8, 9]);
		
		ok $queue->is_empty;
		is($queue->peek_message, undef);
		is_deeply(scalar($queue->peek_messages), []);
		
		# Fetch messages (non-blocking) where nothing new on the server side
		$queue->update_messages;
		
		ok $queue->is_empty;
		is($queue->peek_message, undef);
		is_deeply(scalar($queue->peek_messages), []);
	});
};

subtest messages_during_idle => sub {
	plan tests => 1;
	my $orig_method = \&Mail::IMAPClient::idle;
	my $i = 0;
	my $flip = 0;
	
	no warnings qw(redefine);
	
	local *Mail::IMAPClient::idle = sub {
		my $imap = shift;
		
		if ($i >= 3 && $flip) {
			add_message($imap) foreach 1..2;
		}
		
		$flip = !$flip;
		
		my $ret = $orig_method->($imap, @_);
		return $ret;
	};
	
	my $got = [];
	
	run(sub {
		my ($queue, $imap) = @_;
		
		for ($i = 0; defined(my $msg = $queue->dequeue_message); $i++) {
			push @$got, $msg;
			last if $i >= 6;
		}
	});
	
	is_deeply($got, [1, 2, 3, 4, 5, 6, 7]);
};

# TODO: tests for disconnection
