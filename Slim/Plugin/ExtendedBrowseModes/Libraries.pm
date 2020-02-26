package Slim::Plugin::ExtendedBrowseModes::Libraries;

# Logitech Media Server Copyright 2001-2020 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;

use Slim::Music::VirtualLibraries;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use constant AUDIOBOOK_LIBRARY_ID => 'audioBooks';

my $prefs = preferences('plugin.extendedbrowsemodes');

sub initPlugin {
	shift->initLibraries();
}

sub initLibraries {
	my ($class) = @_;

	if ( $prefs->get('enableLosslessPreferred') ) {
		Slim::Music::VirtualLibraries->registerLibrary({
			id     => 'losslessPreferred',
			name   => string('PLUGIN_EXTENDED_BROWSEMODES_LOSSLESS_PREFERRED'),
			string => 'PLUGIN_EXTENDED_BROWSEMODES_LOSSLESS_PREFERRED',
			sql    => qq{
				INSERT OR IGNORE INTO library_track (library, track)
					SELECT '%s', tracks.id
					FROM tracks, albums
					WHERE albums.id = tracks.album
					AND (
						tracks.lossless
						OR 1 NOT IN (
							SELECT 1
							FROM tracks other
							JOIN albums otheralbums ON other.album
							WHERE other.title = tracks.title
							AND other.lossless
							AND other.primary_artist = tracks.primary_artist
							AND other.tracknum = tracks.tracknum
							AND other.year = tracks.year
							AND otheralbums.title = albums.title
						)
					)
			}
		});
	}

	if ( $prefs->get('enableAudioBooks') ) {
		my $ids = Slim::Plugin::ExtendedBrowseModes::Plugin->valueToId($prefs->get('audioBooksGenres'), 'genre_id');

		Slim::Music::VirtualLibraries->registerLibrary({
			id     => AUDIOBOOK_LIBRARY_ID,
			name   => string('PLUGIN_EXTENDED_BROWSEMODES_AUDIOBOOKS'),
			string => 'PLUGIN_EXTENDED_BROWSEMODES_AUDIOBOOKS',
			sql    => qq{
				INSERT OR IGNORE INTO library_track (library, track)
					SELECT '%s', tracks.id
					FROM tracks, genre_track
					WHERE genre_track.track = tracks.id
					AND genre_track.genre IN ($ids)
			}
		});

		Slim::Music::VirtualLibraries->registerLibrary({
			id     => 'noAudioBooks',
			name   => string('PLUGIN_EXTENDED_BROWSEMODES_NO_AUDIOBOOKS'),
			string => 'PLUGIN_EXTENDED_BROWSEMODES_NO_AUDIOBOOKS',
			sql    => qq{
				INSERT OR IGNORE INTO library_track (library, track)
					SELECT '%s', tracks.id
					FROM tracks, genre_track
					WHERE genre_track.track = tracks.id
					AND genre_track.genre NOT IN ($ids)
			}
		});
	}
}


1;