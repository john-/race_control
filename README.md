Introduction
------------

race_control is for monitoring some automobile racing leaderboards and for control of radio scanners.

Features
--------

* Screen scrapes leaderboards for some automobile racing series.  This includes SCCA and ALMS.  See config for full list
    * Highlights and announces change in position, driver changes, top speed, best lap
    * Auto mode to cycle through configured leaderboards and stop on session activity
* Controls AOR8200 radio scanners as well as provides user interface to display current frequency as well as human readable descriptor (from leaderboard if there is match otherwise from frequency database)
    * Uploads frequencies to scan banks
    * Configuration and UI to control two AOR8200 radios (start scan, search, set frequency from descriptor, set scan/search pass)
    * Initiate bandscope function and store/graph results.
* Provides database of radio frequencies including description and tags (groups)
* Interface to Optoelectronics Digital Scout.  Stores hits from frequency counter and "reaction tune" the radio scanners
* Text to speech interface for most functions
* Speaks (via TTS) changes in weather (temperature, wind direction and speed, etc)
* Stores race weekend schedule and announces pending events (with configurable alert in advance of event)
* Provides controls to record audio and flac encode/tag the recordings
* When searching/scanning, stores gps lat/long

Design
------
* Overall all pretty nasty.  This is consistent with the coding
* Utilizes perl with Tk for UI and POE for most functionality
* The various interfaces have implementations separate from user interface (or at least that is the intent)

Utilities
---------

* Application to manage frequency database

Dependencies
------------

* All sorts of perl modules
* sqlite
* gpsd
* alsa/aplay
* Cepstral text to speech engine (http://www.cepstral.com/)
    * default configuration is Diane/Lawrence voices
* sox
* metaflac

Applicability
-------------

This application is highly tuned to my purpose/hardware.  However, certain bits may be of general interest.

Among many things, this is not intended to be a general purpose interface to the AOR8200 radio.  There are other applications that serve that purpose.

License
-------

Copyright: Everything is copyrighted by me.


    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.