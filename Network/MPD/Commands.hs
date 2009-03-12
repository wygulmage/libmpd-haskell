{-# LANGUAGE PatternGuards, TypeSynonymInstances #-}

-- | Module    : Network.MPD.Commands
-- Copyright   : (c) Ben Sinclair 2005-2008
-- License     : LGPL (see LICENSE)
-- Maintainer  : bsinclai@turing.une.edu.au
-- Stability   : alpha
-- Portability : unportable (uses PatternGuards and TypeSynonymInstances)
--
-- Interface to the user commands supported by MPD.

module Network.MPD.Commands (
    -- * Command related data types
    Artist, Album, Title, PlaylistName, Path,
    Meta(..), Query, (=?),
    module Network.MPD.Types,

    -- * Admin commands
    disableOutput, enableOutput, kill, outputs, update,

    -- * Database commands
    find, list, listAll, listAllInfo, lsInfo, search, count,

    -- * Playlist commands
    -- $playlist
    add, add_, addId, clear, currentSong, delete, load, move,
    playlistInfo, listPlaylist, listPlaylistInfo, playlist, plChanges,
    plChangesPosId, playlistFind, playlistSearch, rm, rename, save, shuffle,
    swap,

    -- * Playback commands
    crossfade, next, pause, play, previous, random, repeat, seek, setVolume,
    volume, stop,

    -- * Miscellaneous commands
    clearError, close, commands, notCommands, password, ping, reconnect, stats,
    status, tagTypes, urlHandlers,

    -- * Extensions\/shortcuts
    addMany, deleteMany, complete, crop, prune, lsDirs, lsFiles, lsPlaylists,
    findArtist, findAlbum, findTitle, listArtists, listAlbums, listAlbum,
    searchArtist, searchAlbum, searchTitle, getPlaylist, toggle, updateId
    ) where

import Network.MPD.Core
import Network.MPD.Utils
import Network.MPD.Parse
import Network.MPD.Types

import Control.Monad (liftM, unless)
import Control.Monad.Error (throwError)
import Data.Monoid
import Prelude hiding (repeat)
import Data.List (findIndex, intersperse, isPrefixOf)
import Data.Maybe
import System.FilePath (dropFileName)

--
-- Data types
--

-- Arguments for getResponse are accumulated as strings in values of
-- this type after being converted from whatever type (an instance of
-- MPDArg) they were to begin with.
newtype Args = Args [String]
    deriving Show

-- A uniform interface for argument preparation
-- The basic idea is that one should be able
-- to magically prepare an argument for use with
-- an MPD command, without necessarily knowing/\caring
-- how it needs to be represented internally.
class Show a => MPDArg a where
    prep :: a -> Args
    -- Note that because of this, we almost
    -- never have to actually provide
    -- an implementation of 'prep'
    prep = Args . return . show

-- | Groups together arguments to getResponse.
infixl 3 <++>
(<++>) :: (MPDArg a, MPDArg b) => a -> b -> Args
x <++> y = Args $ xs ++ ys
    where Args xs = prep x
          Args ys = prep y

-- | Converts a command name and a string of arguments into the string
-- to hand to getResponse.
infix 2 <$>
(<$>) :: (MPDArg a) => String -> a -> String
x <$> y = x ++ " " ++ unwords (filter (not . null) y')
    where Args y' = prep y

instance MPDArg Args where prep = id

instance MPDArg String where
    -- We do this to avoid mangling
    -- non-ascii characters with 'show'
    prep x = Args ['"' : x ++ "\""]

instance (MPDArg a) => MPDArg (Maybe a) where
    prep Nothing = Args []
    prep (Just x) = prep x

instance MPDArg Int
instance MPDArg Integer
instance MPDArg Bool where prep = Args . return . showBool

type Artist       = String
type Album        = String
type Title        = String

-- | Used for commands which require a playlist name.
-- If empty, the current playlist is used.
type PlaylistName = String

-- | Used for commands which require a path within the database.
-- If empty, the root path is used.
type Path         = String

-- | Available metadata types\/scope modifiers, used for searching the
-- database for entries with certain metadata values.
data Meta = Artist | Album | Title | Track | Name | Genre | Date
    | Composer | Performer | Disc | Any | Filename
      deriving Show

instance MPDArg Meta

-- A single query clause, comprising a metadata key and a desired value.
data Match = Match Meta String

instance Show Match where
    show (Match meta query) = show meta ++ " \"" ++ query ++ "\""
    showList xs _ = unwords $ map show xs

-- | An interface for creating MPD queries.
--
-- For example, to match any song where the value of artist is \"Foo\", we
-- use:
--
-- > Artist =? "Foo"
--
-- We can also compose queries, thus narrowing the search. For example, to
-- match any song where the value of artist is \"Foo\" and the value of album
-- is \"Bar\", we use:
--
-- > Artist =? "Foo" `mappend` (Album =? "Bar")
--
-- or:
--
-- > mconcat [Artist =? "Foo", Album =? "Bar"]
--
-- Note that this requires you to
--
-- > import Data.Monoid
newtype Query = Query [Match] deriving Show

instance Monoid Query where
    mempty  = Query []
    Query a `mappend` Query b = Query (a ++ b)

instance MPDArg Query where
    prep = foldl (<++>) (Args []) . f
        where f (Query ms) = map (\(Match m q) -> Args [show m] <++> q) ms

-- | Create a query.
(=?) :: Meta -> String -> Query
m =? s = Query [Match m s]

--
-- Admin commands
--

-- | Turn off an output device.
disableOutput :: Int -> MPD ()
disableOutput = getResponse_ . ("disableoutput" <$>)

-- | Turn on an output device.
enableOutput :: Int -> MPD ()
enableOutput = getResponse_ . ("enableoutput" <$>)

-- | Retrieve information for all output devices.
outputs :: MPD [Device]
outputs = getResponse "outputs" >>= runParser parseOutputs

-- | Update the server's database.
-- If no paths are given, all paths will be scanned.
-- Unreadable or non-existent paths are silently ignored.
update :: [Path] -> MPD ()
update  [] = getResponse_ "update"
update [x] = getResponse_ ("update" <$> x)
update xs  = getResponses (map ("update" <$>) xs) >> return ()

--
-- Database commands
--

-- | List all metadata of metadata (sic).
list :: Meta -- ^ Metadata to list
     -> Query -> MPD [String]
list mtype query = liftM takeValues $ getResponse ("list" <$> mtype <++> query)

-- | Non-recursively list the contents of a database directory.
lsInfo :: Path -> MPD [Either Path Song]
lsInfo = lsInfo' "lsinfo"

-- | List the songs (without metadata) in a database directory recursively.
listAll :: Path -> MPD [Path]
listAll path = liftM (map snd . filter ((== "file") . fst) . toAssoc)
                     (getResponse $ "listall" <$> path)

-- | Recursive 'lsInfo'.
listAllInfo :: Path -> MPD [Either Path Song]
listAllInfo = lsInfo' "listallinfo"

-- Helper for lsInfo and listAllInfo.
lsInfo' :: String -> Path -> MPD [Either Path Song]
lsInfo' cmd path =
    liftM (extractEntries (Just . Right, const Nothing, Just . Left)) $
         takeEntries =<< getResponse (cmd <$> path)

-- | Search the database for entries exactly matching a query.
find :: Query -> MPD [Song]
find query = getResponse ("find" <$> query) >>= takeSongs

-- | Search the database using case insensitive matching.
search :: Query -> MPD [Song]
search query = getResponse ("search" <$> query) >>= takeSongs

-- | Count the number of entries matching a query.
count :: Query -> MPD Count
count query = getResponse ("count" <$>  query) >>= runParser parseCount

--
-- Playlist commands
--
-- $playlist
-- Unless otherwise noted all playlist commands operate on the current
-- playlist.

-- This might do better to throw an exception than silently return 0.
-- | Like 'add', but returns a playlist id.
addId :: Path -> MPD Integer
addId p = liftM (parse parseNum id 0 . snd . head . toAssoc)
              $ getResponse1 ("addid" <$> p)

-- | Like 'add_' but returns a list of the files added.
add :: PlaylistName -> Path -> MPD [Path]
add plname x = add_ plname x >> listAll x

-- | Add a song (or a whole directory) to a playlist.
-- Adds to current if no playlist is specified.
-- Will create a new playlist if the one specified does not already exist.
add_ :: PlaylistName -> Path -> MPD ()
add_ "" path     = getResponse_ ("add" <$> path)
add_ plname path = getResponse_ ("playlistadd" <$> plname <++> path)

-- | Clear a playlist. Clears current playlist if no playlist is specified.
-- If the specified playlist does not exist, it will be created.
clear :: PlaylistName -> MPD ()
clear "" = getResponse_ "clear"
clear pl = getResponse_ ("playlistclear" <$> pl)

-- | Remove a song from a playlist.
-- If no playlist is specified, current playlist is used.
-- Note that a playlist position ('Pos') is required when operating on
-- playlists other than the current.
delete :: PlaylistName -> PLIndex -> MPD ()
delete "" (Pos x) = getResponse_ ("delete" <$> x)
delete "" (ID x)  = getResponse_ ("deleteid" <$> x)
delete plname (Pos x) = getResponse_ ("playlistdelete" <$> plname <++> x)
delete _ _ = fail "'delete' within a playlist doesn't accept a playlist ID"

-- | Load an existing playlist.
load :: PlaylistName -> MPD ()
load plname = getResponse_ ("load" <$> plname)

-- | Move a song to a given position.
-- Note that a playlist position ('Pos') is required when operating on
-- playlists other than the current.
move :: PlaylistName -> PLIndex -> Integer -> MPD ()
move "" (Pos from) to = getResponse_ ("move" <$> from <++> to)
move "" (ID from) to = getResponse_ ("moveid" <$> from <++> to)
move plname (Pos from) to =
    getResponse_ ("playlistmove" <$> plname <++> from <++> to)
move _ _ _ = fail "'move' within a playlist doesn't accept a playlist ID"

-- | Delete existing playlist.
rm :: PlaylistName -> MPD ()
rm plname = getResponse_ ("rm" <$> plname)

-- | Rename an existing playlist.
rename :: PlaylistName -- ^ Original playlist
       -> PlaylistName -- ^ New playlist name
       -> MPD ()
rename plname new = getResponse_ ("rename" <$> plname <++> new)

-- | Save the current playlist.
save :: PlaylistName -> MPD ()
save plname = getResponse_ ("save" <$> plname)

-- | Swap the positions of two songs.
-- Note that the positions must be of the same type, i.e. mixing 'Pos' and 'ID'
-- will result in a no-op.
swap :: PLIndex -> PLIndex -> MPD ()
swap (Pos x) (Pos y) = getResponse_ ("swap" <$> x <++> y)
swap (ID x)  (ID y)  = getResponse_ ("swapid" <$> x <++> y)
swap _ _ = fail "'swap' cannot mix position and ID arguments"

-- | Shuffle the playlist.
shuffle :: MPD ()
shuffle = getResponse_ "shuffle"

-- | Retrieve metadata for songs in the current playlist.
playlistInfo :: Maybe PLIndex -> MPD [Song]
playlistInfo x = getResponse cmd >>= takeSongs
    where cmd = case x of
                    Just (Pos x') -> "playlistinfo" <$> x'
                    Just (ID x')  -> "playlistid"   <$> x'
                    Nothing       -> "playlistinfo"

-- | Retrieve metadata for files in a given playlist.
listPlaylistInfo :: PlaylistName -> MPD [Song]
listPlaylistInfo plname =
    takeSongs =<< getResponse ("listplaylistinfo" <$> plname)

-- | Retrieve a list of files in a given playlist.
listPlaylist :: PlaylistName -> MPD [Path]
listPlaylist plname =
    liftM takeValues $ getResponse ("listplaylist" <$> plname)

-- | Retrieve file paths and positions of songs in the current playlist.
-- Note that this command is only included for completeness sake; it's
-- deprecated and likely to disappear at any time, please use 'playlistInfo'
-- instead.
playlist :: MPD [(PLIndex, Path)]
playlist = mapM f =<< getResponse "playlist"
    where f s | (pos, name) <- breakChar ':' s
              , Just pos'   <- parseNum pos
              = return (Pos pos', name)
              | otherwise = throwError . Unexpected $ show s

-- | Retrieve a list of changed songs currently in the playlist since
-- a given playlist version.
plChanges :: Integer -> MPD [Song]
plChanges version = takeSongs =<< getResponse ("plchanges" <$> version)

-- | Like 'plChanges' but only returns positions and ids.
plChangesPosId :: Integer -> MPD [(PLIndex, PLIndex)]
plChangesPosId plver =
    getResponse ("plchangesposid" <$> plver) >>=
    mapM f . splitGroups [("cpos",id)] . toAssoc
    where f xs | [("cpos", x), ("Id", y)] <- xs
               , Just (x', y') <- pair parseNum (x, y)
               = return (Pos x', ID y')
               | otherwise = throwError . Unexpected $ show xs

-- | Search for songs in the current playlist with strict matching.
playlistFind :: Query -> MPD [Song]
playlistFind q = takeSongs =<< getResponse ("playlistfind" <$> q)

-- | Search case-insensitively with partial matches for songs in the
-- current playlist.
playlistSearch :: Query -> MPD [Song]
playlistSearch q = takeSongs =<< getResponse ("playlistsearch" <$> q)

-- | Get the currently playing song.
currentSong :: MPD (Maybe Song)
currentSong = do
    cs <- status
    if stState cs == Stopped
       then return Nothing
       else getResponse1 "currentsong" >>=
            fmap Just . runParser parseSong . toAssoc

--
-- Playback commands
--

-- | Set crossfading between songs.
crossfade :: Seconds -> MPD ()
crossfade secs = getResponse_ ("crossfade" <$> secs)

-- | Begin\/continue playing.
play :: Maybe PLIndex -> MPD ()
play Nothing        = getResponse_  "play"
play (Just (Pos x)) = getResponse_ ("play"   <$> x)
play (Just (ID x))  = getResponse_ ("playid" <$> x)

-- | Pause playing.
pause :: Bool -> MPD ()
pause = getResponse_ . ("pause" <$>)

-- | Stop playing.
stop :: MPD ()
stop = getResponse_ "stop"

-- | Play the next song.
next :: MPD ()
next = getResponse_ "next"

-- | Play the previous song.
previous :: MPD ()
previous = getResponse_ "previous"

-- | Seek to some point in a song.
-- Seeks in current song if no position is given.
seek :: Maybe PLIndex -> Seconds -> MPD ()
seek (Just (Pos x)) time = getResponse_ ("seek" <$> x <++> time)
seek (Just (ID x)) time = getResponse_ ("seekid" <$> x <++> time)
seek Nothing time = do
    st <- status
    unless (stState st == Stopped) (seek (stSongID st) time)

-- | Set random playing.
random :: Bool -> MPD ()
random = getResponse_ . ("random" <$>)

-- | Set repeating.
repeat :: Bool -> MPD ()
repeat = getResponse_ . ("repeat" <$>)

-- | Set the volume (0-100 percent).
setVolume :: Int -> MPD ()
setVolume = getResponse_ . ("setvol" <$>)

-- | Increase or decrease volume by a given percent, e.g.
-- 'volume 10' will increase the volume by 10 percent, while
-- 'volume (-10)' will decrease it by the same amount.
-- Note that this command is only included for completeness sake ; it's
-- deprecated and may disappear at any time, please use 'setVolume' instead.
volume :: Int -> MPD ()
volume = getResponse_ . ("volume" <$>)

--
-- Miscellaneous commands
--

-- | Clear the current error message in status.
clearError :: MPD ()
clearError = getResponse_ "clearerror"

-- | Retrieve a list of available commands.
commands :: MPD [String]
commands = liftM takeValues (getResponse "commands")

-- | Retrieve a list of unavailable (due to access restrictions) commands.
notCommands :: MPD [String]
notCommands = liftM takeValues (getResponse "notcommands")

-- | Retrieve a list of available song metadata.
tagTypes :: MPD [String]
tagTypes = liftM takeValues (getResponse "tagtypes")

-- | Retrieve a list of supported urlhandlers.
urlHandlers :: MPD [String]
urlHandlers = liftM takeValues (getResponse "urlhandlers")

-- XXX should the password be quoted? Change "++" to "<$>" if so.
-- | Send password to server to authenticate session.
-- Password is sent as plain text.
password :: String -> MPD ()
password = getResponse_ . ("password " ++)

-- | Check that the server is still responding.
ping :: MPD ()
ping = getResponse_ "ping"

-- | Get server statistics.
stats :: MPD Stats
stats = getResponse "stats" >>= runParser parseStats

-- | Get the server's status.
status :: MPD Status
status = getResponse "status" >>= runParser parseStatus

--
-- Extensions\/shortcuts.
--

-- | Like 'update', but returns the update job id.
updateId :: [Path] -> MPD Integer
updateId paths = liftM (read . head . takeValues) cmd
  where cmd = case paths of
                []  -> getResponse  "update"
                [x] -> getResponse ("update" <$> x)
                xs  -> getResponses $ map ("update" <$>) xs

-- | Toggles play\/pause. Plays if stopped.
toggle :: MPD ()
toggle = status >>= \st -> case stState st of Playing -> pause True
                                              _       -> play Nothing

-- | Add a list of songs\/folders to a playlist.
-- Should be more efficient than running 'add' many times.
addMany :: PlaylistName -> [Path] -> MPD ()
addMany _ [] = return ()
addMany plname [x] = add_ plname x
addMany plname xs = getResponses (map cmd xs) >> return ()
    where cmd x = case plname of
                      "" -> "add" <$> x
                      pl -> "playlistadd" <$> pl <++> x

-- | Delete a list of songs from a playlist.
-- If there is a duplicate then no further songs will be deleted, so
-- take care to avoid them (see 'prune' for this).
deleteMany :: PlaylistName -> [PLIndex] -> MPD ()
deleteMany _ [] = return ()
deleteMany plname [x] = delete plname x
deleteMany "" xs = getResponses (map cmd xs) >> return ()
    where cmd (Pos x) = "delete"   <$> x
          cmd (ID x)  = "deleteid" <$> x
deleteMany plname xs = getResponses (map cmd xs) >> return ()
    where cmd (Pos x) = "playlistdelete" <$> plname <++> x
          cmd _       = ""

-- | Returns all songs and directories that match the given partial
-- path name.
complete :: String -> MPD [Either Path Song]
complete path = do
    xs <- liftM matches . lsInfo $ dropFileName path
    case xs of
        [Left dir] -> complete $ dir ++ "/"
        _          -> return xs
    where
        matches = filter (isPrefixOf path . takePath)
        takePath = either id sgFilePath

-- | Crop playlist.
-- The bounds are inclusive.
-- If 'Nothing' or 'ID' is passed the cropping will leave your playlist alone
-- on that side.
crop :: Maybe PLIndex -> Maybe PLIndex -> MPD ()
crop x y = do
    pl <- playlistInfo Nothing
    let x' = case x of Just (Pos p) -> fromInteger p
                       Just (ID i)  -> fromMaybe 0 (findByID i pl)
                       Nothing      -> 0
        -- ensure that no songs are deleted twice with 'max'.
        ys = case y of Just (Pos p) -> drop (max (fromInteger p) x') pl
                       Just (ID i)  -> maybe [] (flip drop pl . max x' . (+1))
                                      (findByID i pl)
                       Nothing      -> []
    deleteMany "" . mapMaybe sgIndex $ take x' pl ++ ys
    where findByID i = findIndex ((==) i . (\(ID j) -> j) . fromJust . sgIndex)

-- | Remove duplicate playlist entries.
prune :: MPD ()
prune = findDuplicates >>= deleteMany ""

-- Find duplicate playlist entries.
findDuplicates :: MPD [PLIndex]
findDuplicates =
    liftM (map ((\(ID x) -> ID x) . fromJust . sgIndex) . flip dups ([],[])) $
        playlistInfo Nothing
    where dups [] (_, dup) = dup
          dups (x:xs) (ys, dup)
              | x `mSong` xs && not (x `mSong` ys) = dups xs (ys, x:dup)
              | otherwise                          = dups xs (x:ys, dup)
          mSong x = let m = sgFilePath x in any ((==) m . sgFilePath)

-- | List directories non-recursively.
lsDirs :: Path -> MPD [Path]
lsDirs path =
    liftM (extractEntries (const Nothing,const Nothing, Just)) $
        takeEntries =<< getResponse ("lsinfo" <$> path)

-- | List files non-recursively.
lsFiles :: Path -> MPD [Path]
lsFiles path =
    liftM (extractEntries (Just . sgFilePath, const Nothing, const Nothing)) $
        takeEntries =<< getResponse ("lsinfo" <$> path)

-- | List all playlists.
lsPlaylists :: MPD [PlaylistName]
lsPlaylists = liftM (extractEntries (const Nothing, Just, const Nothing)) $
                    takeEntries =<< getResponse "lsinfo"

-- | Search the database for songs relating to an artist.
findArtist :: Artist -> MPD [Song]
findArtist x = find (Artist =? x)

-- | Search the database for songs relating to an album.
findAlbum :: Album -> MPD [Song]
findAlbum  x = find (Album =? x)

-- | Search the database for songs relating to a song title.
findTitle :: Title -> MPD [Song]
findTitle x = find (Title =? x)

-- | List the artists in the database.
listArtists :: MPD [Artist]
listArtists = liftM takeValues (getResponse "list artist")

-- | List the albums in the database, optionally matching a given
-- artist.
listAlbums :: Maybe Artist -> MPD [Album]
listAlbums artist = liftM takeValues $
                    getResponse ("list album" <$> fmap ("artist" <++>) artist)

-- | List the songs in an album of some artist.
listAlbum :: Artist -> Album -> MPD [Song]
listAlbum artist album = find $ mconcat [Artist =? artist, Album =? album]

-- | Search the database for songs relating to an artist using 'search'.
searchArtist :: Artist -> MPD [Song]
searchArtist x = search (Artist =? x)

-- | Search the database for songs relating to an album using 'search'.
searchAlbum :: Album -> MPD [Song]
searchAlbum x = search (Album =? x)

-- | Search the database for songs relating to a song title.
searchTitle :: Title -> MPD [Song]
searchTitle x = search (Title =? x)

-- | Retrieve the current playlist.
-- Equivalent to @playlistinfo Nothing@.
getPlaylist :: MPD [Song]
getPlaylist = playlistInfo Nothing

--
-- Miscellaneous functions.
--

-- Run getResponse but discard the response.
getResponse_ :: String -> MPD ()
getResponse_ x = getResponse x >> return ()

-- Get the lines of the daemon's response to a list of commands.
getResponses :: [String] -> MPD [String]
getResponses cmds = getResponse . concat $ intersperse "\n" cmds'
    where cmds' = "command_list_begin" : cmds ++ ["command_list_end"]

-- Helper that throws unexpected error if input is empty.
failOnEmpty :: [String] -> MPD [String]
failOnEmpty [] = throwError $ Unexpected "Non-empty response expected."
failOnEmpty xs = return xs

-- A wrapper for getResponse that fails on non-empty responses.
getResponse1 :: String -> MPD [String]
getResponse1 x = getResponse x >>= failOnEmpty

--
-- Parsing.
--

-- Run 'toAssoc' and return only the values.
takeValues :: [String] -> [String]
takeValues = snd . unzip . toAssoc

data EntryType
    = SongEntry Song
    | PLEntry   String
    | DirEntry  String
      deriving Show

-- Separate the result of an lsinfo\/listallinfo call into directories,
-- playlists, and songs.
takeEntries :: [String] -> MPD [EntryType]
takeEntries = mapM toEntry . splitGroups wrappers . toAssoc . reverse
    where
        toEntry xs@(("file",_):_)   = liftM SongEntry $ runParser parseSong xs
        toEntry (("directory",d):_) = return $ DirEntry d
        toEntry (("playlist",pl):_) = return $ PLEntry  pl
        toEntry _ = error "takeEntries: splitGroups is broken"
        wrappers = [("file",id), ("directory",id), ("playlist",id)]

-- Extract a subset of songs, directories, and playlists.
extractEntries :: (Song -> Maybe a, String -> Maybe a, String -> Maybe a)
               -> [EntryType] -> [a]
extractEntries (fSong,fPlayList,fDir) = catMaybes . map f
    where
        f (SongEntry s) = fSong s
        f (PLEntry pl)  = fPlayList pl
        f (DirEntry d)  = fDir d

-- Build a list of song instances from a response.
takeSongs :: [String] -> MPD [Song]
takeSongs = mapM (runParser parseSong) . splitGroups [("file",id)] . toAssoc
