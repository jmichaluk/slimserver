package Slim::Plugin::LastFM::Plugin;

# $Id$

# Play Last.fm Radio via mysqueezebox.com

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Networking::SqueezeNetwork;
use Slim::Plugin::LastFM::ProtocolHandler;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Unicode;

use URI::Escape qw(uri_escape_utf8);

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.lfm',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_LFM_MODULE_NAME',
} );

my $prefs = preferences('plugin.audioscrobbler');

sub initPlugin {
	my $class = shift;
	
	Slim::Player::ProtocolHandlers->registerHandler(
		lfm => 'Slim::Plugin::LastFM::ProtocolHandler'
	);
	
	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr/squeezenetwork\.com.*\/lastfm\//, 
		sub { return $class->_pluginDataFor('icon'); }
	);

	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( lfm => (
		after => 'middle',
		func  => \&trackInfoMenu,
	) );
	
	# Commands init
	Slim::Control::Request::addDispatch(['lfm', 'rate', '_rating'],
		[0, 1, 1, \&rateTrack]);
			
	Slim::Control::Request::addDispatch(['lfm', 'skipTrack'],
		[0, 1, 1, \&skipTrack]);
	
	$class->SUPER::initPlugin(
		tag    => 'lfm',
		menu   => 'music_services',
		weight => 40,
		is_app => 1,
	);
	
	if ( main::SLIM_SERVICE ) {
		my $menu = {
			useMode => sub { $class->setMode(@_) },
			header  => 'PLUGIN_LFM_MODULE_NAME',
		};
		
		# Add as top-level item choice
		Slim::Buttons::Home::addMenuOption(
			'PLUGIN_LFM_MODULE_NAME',
			$menu,
		);
	}
	
	if ( main::WEBUI ) {
		# Add a function to view trackinfo in the web
		Slim::Web::Pages->addPageFunction( 
			'plugins/lastfm/trackinfo.html',
			sub {
				my $client = $_[0];
				
				my $url = Slim::Player::Playlist::url($client);
				
				Slim::Web::XMLBrowser->handleWebIndex( {
					feed    => Slim::Plugin::LastFM::ProtocolHandler->trackInfoURL( $client, $url ),
					path    => 'plugins/lastfm/trackinfo.html',
					title   => 'Last.fm Track Info',
					timeout => 35,
					args    => \@_
				} );
			},
		);
	}
}

sub getDisplayName () {
	return 'PLUGIN_LFM_MODULE_NAME';
}

# Don't add this item to any menu
sub playerMenu { }

sub feed {
	my ( $class, $client ) = @_;
	
	my $url = Slim::Networking::SqueezeNetwork->url('/api/lastfm/v1/opml');
	
	# Add account to URL, if account is not configured SN will provide an error message
	# instructing user to select an account for this player
	if ( $client ) {
		my $account = $prefs->client($client)->get('account');
		
		if ( $account ) {
			$url .= '?account=' . uri_escape_utf8($account);
		}		
	}
	
	return $url;
}

sub rateTrack {
	my $request = shift;
	my $client  = $request->client();
	
	return unless defined $client;
	
	my $song = $client->playingSong() || return;
	
	# ignore if user is not using Last.fm
	my $url = $song->currentTrack()->url;
	return unless $url =~ /^lfm/;
	
	my $rating = $request->getParam('_rating');
	
	if ( $rating !~ /^[LB]$/ ) {
		main::DEBUGLOG && $log->debug('Invalid Last.fm rating, must be L or B');
		return;
	}
	
	# Get the current track
	my $currentTrack = $song->pluginData() || return;
	
	my ($station) = $url =~ m{^lfm://(.+)};
	
	my $account = $prefs->client($client)->get('account');
	
	# SN URL to submit rating
	my $ratingURL = Slim::Networking::SqueezeNetwork->url(
		  '/api/lastfm/v1/opml/trackinfo/rate?account=' . uri_escape_utf8($account)
		. '&station=' . uri_escape_utf8($station)
		. '&track='   . uri_escape_utf8( $currentTrack->{title} )
		. '&artist='  . uri_escape_utf8( $currentTrack->{creator} )
		. '&rating='  . $rating
	);
	
	main::DEBUGLOG && $log->debug("Last.fm: rateTrack: $rating ($ratingURL)");
	
	my $http = Slim::Networking::SqueezeNetwork->new(
		\&_rateTrackOK,
		\&_rateTrackError,
		{
			client       => $client,
			request      => $request,
			url          => $url,
			currentTrack => $currentTrack,
			timeout      => 35,
		},
	);
	
	$http->get( $ratingURL );
	
	$request->setStatusProcessing();
}

sub _rateTrackOK {
	my $http    = shift;
	my $client  = $http->params('client');
	my $request = $http->params('request');
	
	my $rating       = $request->getParam('_rating');
	my $currentTrack = $http->params('currentTrack');
	my $url          = $http->params('url');
	
	main::DEBUGLOG && $log->debug('Rating submit OK');
	
	# If rating was ban and skip is allowed, skip the track
	if ( $rating eq 'B' ) {
		main::DEBUGLOG && $log->debug('Rating was ban, passing to AudioScrobbler');
		$client->execute( [ 'audioscrobbler', 'banTrack', $url, $currentTrack->{canSkip} ] );
	}
	else {
		main::DEBUGLOG && $log->debug('Rating was love, passing to AudioScrobbler');
		$client->execute( [ 'audioscrobbler', 'loveTrack', $url ] );
	}
	
	# Parse the text out of the JSON
	my ($text) = $http->content =~ m/"text":"([^"]+)/;	
	$request->addResult( text => Slim::Utils::Unicode::utf8on($text) );
	
	$request->setStatusDone();
}

sub _rateTrackError {
	my $http    = shift;
	my $error   = $http->error;
	my $client  = $http->params('client');
	my $request = $http->params('request');
	
	main::DEBUGLOG && $log->debug( "Rating submit error: $error" );
	
	# Not sure what status to use here
	$request->setStatusBadParams();
}

sub skipTrack {
	my $request = shift;
	my $client  = $request->client();
	
	return unless defined $client;
	
	# ignore if user is not using Last.fm
	my $song = $client->playingSong() || return;
	my $url = $song->currentTrack()->url;
	return unless $url =~ /^lfm/;
		
	main::DEBUGLOG && $log->debug("Last.fm: Skip requested");
		
	$client->execute( [ "playlist", "jump", "+1" ] );
}

sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	
	return unless $client;
	
	# Only show if in the app list
	return unless $client->isAppEnabled('lastfm');
	
	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	
	my $snURL = Slim::Networking::SqueezeNetwork->url(
		'/api/lastfm/v1/opml/search_artist?q=' . uri_escape_utf8($artist)
	);
	
	if ( $artist ) {
		return {
			type        => 'link',
			name        => cstring($client, 'PLUGIN_LFM_ON_LASTFM'),
			url         => $snURL,
			favorites   => 0,
		};
	}
	
	return;
}

1;
