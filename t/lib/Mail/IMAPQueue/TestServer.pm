use 5.008_001;
use strict;
use warnings;

package Mail::IMAPQueue::TestServer;

use IO::Socket::INET;
use List::Util qw(max);

sub new {
	my ($class, $init_uids) = @_;
	my $server_sock;
	my $port;
	
	my $min_port = $ENV{MAIL_IMAPQUEUE_TESTSERVER_MINPORT} || 20000;
	my $max_port = $ENV{MAIL_IMAPQUEUE_TESTSERVER_MAXPORT} || ($min_port + 1000);
	
	for ($port = $min_port; $port <= $max_port; $port++) {
		last if $server_sock = IO::Socket::INET->new(
			LocalPort => $port,
			Proto     => 'tcp',
			ReuseAddr => 1,
			Listen    => 5,
		);
	}
	
	return undef unless $server_sock;
	$server_sock->close;
	undef $server_sock;
	
	my $pid = fork;
	die "fork failed: $!" unless defined $pid;
	
	if ($pid) {
		# Parent process
		return bless {
			pid => $pid,
			port => $port,
			min_port => $min_port,
		}, $class;
	} else {
		# Child process (run server in background)
		$server_sock = IO::Socket::INET->new(
			LocalPort => $port,
			Proto     => 'tcp',
			ReuseAddr => 1,
			Listen    => 1,
		) or die "failed to start server at port $port: $@";
		
		_run_server($server_sock, $init_uids);
		$server_sock->close;
		exit;
	}
}

sub connect_client {
	my ($server) = @_;
	my $client_sock;
	
	until ($client_sock) {
		$client_sock = IO::Socket::INET->new(
			PeerHost => 'localhost',
			PeerPort => $server->{port},
			Proto => 'tcp',
		) or do {sleep 0.1};
	}
	
	return $client_sock;
}

sub _run_server {
	my ($server_sock, $init_uids) = @_;
	my $uidvalidity = 'foo';
	
	while (my $client_sock = $server_sock->accept) {
		my $uids = [@$init_uids];
		my $uidnext = max(@$uids) + 1;
		
		print $client_sock "* OK\r\n";
		
		while (<$client_sock>) {
			chomp;
			my @chunks;
			
			while (/("([^"]|\\")*"|'([^']|\\')*'|\S+)/g) {
				push @chunks, $1;
			}
			
			my $tag = shift @chunks;
			my $for_uid = 0;
			
			if ($chunks[0] eq 'UID') {
				$for_uid = 1;
				shift @chunks;
			}
			
			my ($cmd, @args) = @chunks;
			
			if ($cmd eq 'SEARCH') {
				my $found = [];
				
				if ($args[0] eq 'ALL') {
					$found = $uids;
				} elsif ($args[0] eq 'UID') {
					if ($args[1] =~ /(\d+):\*/) {
						my $min = $1;
						$found = [grep {$_ >= $min} @$uids];
						
						# RFC 3501 says, the range search with a star (*) will
						# always include the current max uid in the mailbox,
						# unless the mailbox is empty.
						$found = [$uids->[$#$uids]] if @$found == 0 && @$uids > 0;
					}
				}
				
				print $client_sock "* SEARCH @$found\r\n";
			} elsif ($cmd eq 'STATUS') {
				my ($folder, $params) = @args;
				
				if ($params eq '(UIDNEXT)') {
					print $client_sock "* STATUS $folder (UIDNEXT $uidnext)\r\n";
				} elsif ($params eq '(UIDVALIDITY)') {
					print $client_sock "* STATUS $folder (UIDVALIDITY $uidvalidity)\r\n";
				}
			} elsif ($cmd eq 'APPEND') {
				print $client_sock "+\r\n";
				push @$uids, $uidnext++;
				<$client_sock>; # Text
			} elsif ($cmd eq 'IDLE') {
				print $client_sock "+\r\n";
				print $client_sock "* 0 RECENT\r\n";
				<$client_sock>; # DONE
			}
			
			print $client_sock "$tag OK\r\n";
			last if $cmd eq 'CLOSE';
		}
		
		$client_sock->shutdown(2);
		$client_sock->close;
	}
}

sub stop {
	my ($self) = @_;
	kill INT => $self->{pid};
}

1;
