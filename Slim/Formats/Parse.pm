package Slim::Formats::Parse;

# $Id: Parse.pm,v 1.22 2004/10/08 06:04:28 vidur Exp $

# SlimServer Copyright (c) 2001-2004 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

use strict;
use File::Spec::Functions qw(:ALL);
use FileHandle;
use IO::Socket qw(:crlf);
use IO::String;
use XML::Simple;
use URI::Escape;

use Slim::Utils::Misc;

%Slim::Player::Source::playlistInfo = ( 
	'm3u' => [\&M3U, \&writeM3U, '.m3u'],
	'pls' => [\&PLS, \&writePLS, '.pls'],
	'cue' => [\&CUE, undef, undef],
	'wpl' => [\&WPL, \&writeWPL, '.wpl'],
	'asx' => [\&ASX, undef, '.asx'],
	'wax' => [\&ASX, undef, '.wax'],
);

sub parseList {
	my $list = shift;
	my $file = shift;
	my $base = shift;
	my @items;
	
	my $type = Slim::Music::Info::contentType($list);
	my $parser;
	if (exists $Slim::Player::Source::playlistInfo{$type} &&
	    ($parser = $Slim::Player::Source::playlistInfo{$type}->[0])) {
	    return &$parser($file, $base);
	}
}

sub writeList {
	my $listref = shift;
	my $playlistname = shift;
	my $fulldir = shift;
    
	my $type = Slim::Music::Info::typeFromSuffix($fulldir);
	my $writer;
	if (exists $Slim::Player::Source::playlistInfo{$type} &&
	    ($writer = $Slim::Player::Source::playlistInfo{$type}->[1])) {
	    return &$writer($listref, $playlistname, 
						Slim::Utils::Misc::pathFromFileURL($fulldir));
	}
}

sub getPlaylistSuffix {
	my $filepath = shift;

	my $type = Slim::Music::Info::contentType($filepath);
	if (exists $Slim::Player::Source::playlistInfo{$type}) {
		return $Slim::Player::Source::playlistInfo{$type}->[2];
	}

	return undef;
}

sub _updateMetaData {
	my $entry = shift;
	my $title = shift;

	if (Slim::Music::Info::isCached($entry)) {

		if (!Slim::Music::Info::isKnownType($entry)) {
			$::d_parse && Slim::Utils::Misc::msg("    entry: $entry not known type\n"); 
			Slim::Music::Info::setContentType($entry,'mp3');
		}

	} else {
		Slim::Music::Info::setContentType($entry,'mp3');
	}

	if (defined($title)) {
		Slim::Music::Info::setTitle($entry, $title);
		$title = undef;
	}
}

sub M3U {
	my $m3u    = shift;
	my $m3udir = shift;

	my @items  = ();
	
	$::d_parse && Slim::Utils::Misc::msg("parsing M3U: $m3u\n");
	my $title;
	while (my $entry = <$m3u>) {

		chomp($entry);
		# strip carriage return from dos playlists
		$entry =~ s/\cM//g;  

		# strip whitespace from beginning and end
		$entry =~ s/^\s*//; 
		$entry =~ s/\s*$//; 

		$::d_parse && Slim::Utils::Misc::msg("  entry from file: $entry\n");

		

		if ($entry =~ /^#EXTINF:.*?,(.*)$/) {
			$title = $1;	
		}
		
		next if $entry =~ /^#/;
		next if $entry eq "";

		$entry =~ s|$LF||g;
		
		$entry = Slim::Utils::Misc::fixPath($entry, $m3udir);
		
		$::d_parse && Slim::Utils::Misc::msg("    entry: $entry\n");

		_updateMetaData($entry, $title);
		$title = undef;
		push @items, $entry;
	}

	$::d_parse && Slim::Utils::Misc::msg("parsed " . scalar(@items) . " items in m3u playlist\n");

	return @items;
}

sub PLS {
	my $pls = shift;

	my @urls   = ();
	my @titles = ();
	my @items  = ();
	
	# parse the PLS file format

	$::d_parse && Slim::Utils::Misc::msg("Parsing playlist: $pls \n");
	
	while (<$pls>) {
		$::d_parse && Slim::Utils::Misc::msg("Parsing line: $_\n");

		# strip carriage return from dos playlists
		s/\cM//g;  

		# strip whitespace from end
		s/\s*$//; 
		
		if (m|File(\d+)=(.*)|i) {
			$urls[$1] = $2;
			next;
		}
		
		if (m|Title(\d+)=(.*)|i) {
			$titles[$1] = $2;
			next;
		}	
	}

	for (my $i = 1; $i <= $#urls; $i++) {

		next unless defined $urls[$i];

		my $entry = $urls[$i];

		$entry = Slim::Utils::Misc::fixPath($entry);
		
		my $title = $titles[$i];

		_updateMetaData($entry, $title);

		push @items, $entry;
	}

	return @items;
}

sub parseCUE {
	my $lines = shift;
	my $cuedir = shift;
	my @items;

	my $album;
	my $year;
	my $genre;
	my $comment;
	my $filename;
	my $currtrack;
	my %tracks;
	
	foreach (@$lines) {

		# strip whitespace from end
		s/\s*$//; 

		if (/^TITLE\s+\"(.*)\"/i) {
			$album = $1;
		} elsif (/^YEAR\s+\"(.*)\"/i) {
			$year = $1;
		} elsif (/^GENRE\s+\"(.*)\"/i) {
			$genre = $1;
		} elsif (/^COMMENT\s+\"(.*)\"/i) {
			$comment = $1;
		} elsif (/^FILE\s+\"(.*)\"/i) {
			$filename = $1;
			$filename = Slim::Utils::Misc::fixPath($filename, $cuedir);
		} elsif (/^\s+TRACK\s+(\d+)\s+AUDIO/i) {
			$currtrack = int ($1);
		} elsif (defined $currtrack and /^\s+PERFORMER\s+\"(.*)\"/i) {
			$tracks{$currtrack}->{'ARTIST'} = $1;
		} elsif (defined $currtrack and
			 /^\s+(TITLE|YEAR|GENRE|COMMENT)\s+\"(.*)\"/i) {
		   $tracks{$currtrack}->{uc $1} = $2;
		} elsif (defined $currtrack and
			 /^\s+INDEX\s+01\s+(\d+):(\d+):(\d+)/i) {
			$tracks{$currtrack}->{'START'} = ($1 * 60) + $2 + ($3 / 75);
		} elsif (defined $currtrack and
			 /^\s*REM\s+END\s+(\d+):(\d+):(\d+)/i) {
			$tracks{$currtrack}->{'END'} = ($1 * 60) + $2 + ($3 / 75);
		}
	}

	# calc song ending times from start of next song from end to beginning.
	my $lastpos = (defined $tracks{$currtrack}->{'END'}) 
		? $tracks{$currtrack}->{'END'} 
		: Slim::Music::Info::durationSeconds($filename);
	foreach my $key (sort {$b <=> $a} keys %tracks) {
		my $track = $tracks{$key};
		if (!defined $track->{'END'}) {$track->{'END'} = $lastpos};
		$lastpos = $track->{'START'};
	}

	foreach my $key (sort {$a <=> $b} keys %tracks) {

		my $track = $tracks{$key};
		if (!defined $track->{'START'} || !defined $track->{'END'} || !defined $filename ) { next; }
		my $url = "$filename#".$track->{'START'}."-".$track->{'END'};
		$::d_parse && Slim::Utils::Misc::msg("    url: $url\n");

		push @items, $url;

		my $cacheEntry = Slim::Music::Info::cacheEntry($url);
		
		$cacheEntry->{'CT'} = Slim::Music::Info::typeFromPath($url, 'mp3');
		
		$cacheEntry->{'TRACKNUM'} = $key;
		$::d_parse && Slim::Utils::Misc::msg("    tracknum: $key\n");

		if (exists $track->{'TITLE'}) {
			$cacheEntry->{'TITLE'} = $track->{'TITLE'};
			$::d_parse && Slim::Utils::Misc::msg("    title: " . $cacheEntry->{'TITLE'} . "\n");
		}

		if (exists $track->{'ARTIST'}) {
			$cacheEntry->{'ARTIST'} = $track->{'ARTIST'};
			$::d_parse && Slim::Utils::Misc::msg("    artist: " . $cacheEntry->{'ARTIST'} . "\n");
		}

		if (exists $track->{'YEAR'}) {

			$cacheEntry->{'YEAR'} = $track->{'YEAR'};
			$::d_parse && Slim::Utils::Misc::msg("    year: " . $cacheEntry->{'YEAR'} . "\n");
		} elsif (defined $year) {

			$cacheEntry->{'YEAR'} = $year;
			$::d_parse && Slim::Utils::Misc::msg("    year: " . $year . "\n");
		}

		if (exists $track->{'GENRE'}) {

			$cacheEntry->{'GENRE'} = $track->{'GENRE'};
			$::d_parse && Slim::Utils::Misc::msg("    genre: " . $cacheEntry->{'GENRE'} . "\n");
		} elsif (defined $genre) {

			$cacheEntry->{'GENRE'} = $genre;
			$::d_parse && Slim::Utils::Misc::msg("    genre: " . $genre . "\n");
		}

		if (exists $track->{'COMMENT'}) {

			$cacheEntry->{'COMMENT'} = $track->{'COMMENT'};
			$::d_parse && Slim::Utils::Misc::msg("    comment: " . $cacheEntry->{'COMMENT'} . "\n");

		} elsif (defined $comment) {

			$cacheEntry->{'COMMENT'} = $comment;
			$::d_parse && Slim::Utils::Misc::msg("    comment: " . $comment . "\n");
		}

		if (defined $album) {
			$cacheEntry->{'ALBUM'} = $album;
			$::d_parse && Slim::Utils::Misc::msg("    album: " . $cacheEntry->{'ALBUM'} . "\n");
		}

		Slim::Music::Info::readTags($url);
		Slim::Music::Info::updateCacheEntry($url, $cacheEntry);
		$cacheEntry = Slim::Music::Info::cacheEntry($url); #grab the merged info
		Slim::Music::Info::updateGenreCache($url, $cacheEntry);

	}

	$::d_parse && Slim::Utils::Misc::msg("    returning: " . scalar(@items) . " items\n");	
	return @items;
}

sub CUE {
	my $cuefile = shift;
	my $cuedir  = shift;

	$::d_parse && Slim::Utils::Misc::msg("Parsing cue: $cuefile \n");

	my @lines = ();

	while (my $line = <$cuefile>) {
		chomp($line);
		$line =~ s/\cM//g;  
		push @lines, $line;
	}

	return (parseCUE([@lines], $cuedir));
}

sub writePLS {
	my $listref = shift;
	my $playlistname = shift || "SlimServer " . Slim::Utils::Strings::string("PLAYLIST");
	my $filename = shift;
	my $output;
	my $outstring = '';
	my $writeproc;

	if ($filename) {

		$output = FileHandle->new($filename, "w") || do {
			Slim::Utils::Misc::msg("Could not open $filename for writing.\n");
			return;
		};

	} else {

		$output = IO::String->new($outstring);
	}

	print $output "[playlist]\nPlaylistName=$playlistname\n";
	my $itemnum = 0;

	foreach my $item (@{$listref}) {

		$itemnum++;
		my $path = Slim::Music::Info::isFileURL($item) ? Slim::Utils::Misc::pathFromFileURL($item) : $item;
		print $output "File$itemnum=$path\n";

		my $title = Slim::Music::Info::title($item);

		if ($title) {
			print $output "Title$itemnum=$title\n";
		}

		my $dur = Slim::Music::Info::duration($item) || -1;
		print $output "Length$itemnum=$dur\n";
	}

	print $output "NumberOfItems=$itemnum\nVersion=2\n";

	if ($filename) {
		close $output;
		return;
	}

	return $outstring;
}

sub writeM3U {
	my $listref = shift;
	my $playlistname = shift;
	my $filename = shift;
	my $addTitles = shift;
	my $resumetrack = shift;
	my $output;
	my $outstring = '';
	my $writeproc;

	if ($filename) {

		$output = FileHandle->new($filename, "w") || do {
			Slim::Utils::Misc::msg("Could not open $filename for writing.\n");
			return;
		};

	} else {
		$output = IO::String->new($outstring);
	}

	print $output "#CURTRACK $resumetrack\n" if defined($resumetrack);
	print $output "#EXTM3U\n" if $addTitles;

	foreach my $item (@{$listref}) {

		if ($addTitles && Slim::Music::Info::isURL($item)) {

			my $title = Slim::Music::Info::title($item);

			if ($title) {
				print $output "#EXTINF:-1,$title\n";
			}
		}
		my $path = Slim::Music::Info::isFileURL($item) ? Slim::Utils::Misc::pathFromFileURL($item) : $item;
		print $output "$path\n";
	}

	if ($filename) {
		close $output;
		return;
	}

	return $outstring;
}

sub WPL {
	my $wplfile = shift;
	my $wpldir  = shift;

	my @items  = ();

	# Handles version 1.0 WPL Windows Medial Playlist files...
	my $wpl_playlist={};
	eval {
		$wpl_playlist=XMLin($wplfile);
	};

	$::d_parse && Slim::Utils::Misc::msg("parsing WPL: $wplfile\n");

	if(exists($wpl_playlist->{body}->{seq}->{media})) {
		foreach my $entry_info (@{$wpl_playlist->{body}->{seq}->{media}}) {

			my $entry=$entry_info->{src};

			$::d_parse && Slim::Utils::Misc::msg("  entry from file: $entry\n");
		
			$entry = Slim::Utils::Misc::fixPath($entry, $wpldir);
		
			$::d_parse && Slim::Utils::Misc::msg("    entry: $entry\n");

			_updateMetaData($entry, undef);
			push @items, $entry;
		}
	}

	$::d_parse && Slim::Utils::Misc::msg("parsed " . scalar(@items) . " items in wpl playlist\n");

	return @items;
}

sub writeWPL {
	my $listref = shift;
	my $playlistname = shift || "SlimServer " . Slim::Utils::Strings::string("PLAYLIST");
	my $filename = shift;

	# Handles version 1.0 WPL Windows Medial Playlist files...

	# Load the original if it exists (so we don't lose all of the extra crazy info in the playlist...
	my $wpl_playlist={};
	eval {
		$wpl_playlist=XMLin($filename, KeepRoot => 1, ForceArray => 1);
	};

	if($wpl_playlist) {
		# Clear out the current playlist entries...
		$wpl_playlist->{smil}->[0]->{body}->[0]->{seq}->[0]->{media}=[];
	} else {
		# Create a skeleton of the structure we'll need to output a compatible WPL file...
		$wpl_playlist={
			smil => [{
				body => [{
					seq => [{
						media => [
						]
					}]
				}],
				head => [{
					title => [''],
					author => [''],
					meta => {
						Generator => {
							content => '',
						}
					}
				}]
			}]
		};
	}

	foreach my $item (@{$listref}) {

		if (Slim::Music::Info::isURL($item)) {
			my $url=uri_unescape($item);
			$url=~s/^file:[\/\\]+//;
			push(@{$wpl_playlist->{smil}->[0]->{body}->[0]->{seq}->[0]->{media}},{src => $url});
		}
	}

	# XXX - Windows Media Player 9 has problems with directories,
	# and files that have an &amp; in them...

	# Generate our XML for output...
	# (the ForceArray option when we do "XMLin" makes the hash messy,
	# but ensures that we get the same style of XML layout back on
	# "XMLout")
	my $wplfile=XMLout($wpl_playlist, XMLDecl => '<?wpl version="1.0"?>', RootName => undef);
	if ($filename) {

		my $output = FileHandle->new($filename, "w") || do {
			Slim::Utils::Misc::msg("Could not open $filename for writing.\n");
			return;
		};
		print $output "$wplfile";
		close $output;
		return;

	} else {

		my $outstring;
		my $output = IO::String->new($outstring);
		print $output "$wplfile";
		return($outstring);

	}

}

sub ASX {
	my $asxfile = shift;
	my $asxdir  = shift;

	my @items  = ();

	my $asx_playlist={};
	eval {
		$asx_playlist=XMLin($asxfile, ForceArray => ['entry', 'ref']);
	};

	$::d_parse && Slim::Utils::Misc::msg("parsing ASX: $asxfile\n");

	if (exists $asx_playlist->{entry}) {
		foreach my $entry (@{$asx_playlist->{entry}}) {

			my $title = $entry->{title};
			$::d_parse && 
			  Slim::Utils::Misc::msg("Found an entry title: $title\n");
			my $path;
			if (exists $entry->{ref}) {
				for my $ref (@{$entry->{ref}}) {
					my $url = URI->new($ref->{href});
					$::d_parse && 
					  Slim::Utils::Misc::msg("Checking if we can handle the url: $url\n");

					my $scheme = $url->scheme();
					if (exists $Slim::Player::Source::protocolHandlers{lc $scheme}) {
						$::d_parse && 
						  Slim::Utils::Misc::msg("Found a handler for: $url\n");
						$path = $ref->{href};
						last;
					}
				}
			}

			if (defined($path)) {
				$path = Slim::Utils::Misc::fixPath($path, $asxdir);
		
				_updateMetaData($path, $title);
				push @items, $path;
			}
		}
	}

	$::d_parse && Slim::Utils::Misc::msg("parsed " . scalar(@items) . " items in asx playlist\n");

	return @items;
}

1;
__END__

# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
