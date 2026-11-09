{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SlideBlaster.Presentation.Route
-- Description : Sections and routes: ordered branching over a deck's frames.
--
-- A deck's frames fall into a lead (the title slide and every slide before the
-- first section) and sections, each a run of frames. A route is an ordered list
-- of section ids; the first route is the default. Pure and total: unknown or
-- repeated section ids in a route are ignored here (validation reports them),
-- and a deck without routes has one implicit route in file order, so every
-- function below degrades to plain file order.
module SlideBlaster.Presentation.Route
  ( Section (..)
  , Routes (..)
  , Position (..)
  , RouteIssue (..)
  , mkRoutes
  , routeIds
  , defaultRoute
  , routeFrames
  , routeSections
  , sectionOfFrame
  , position
  , frameAfterChoice
  , validateRoutes
  , exportOrder
  , continuations
  ) where

import Data.List (elemIndex, nub)
import Data.Maybe (listToMaybe)
import Data.Text (Text)

-- | A section and the frames it holds, in file order.
data Section = Section
  { sectionId :: !Text
  , sectionTitle :: !Text
  , sectionFrames :: ![Text]
  }
  deriving stock (Eq, Show)

data Routes = Routes
  { routesLead :: ![Text]
  -- ^ Frames that belong to no section; first in every route.
  , routesSections :: ![Section]
  -- ^ Sections in file order.
  , routesDefs :: ![(Text, [Text])]
  -- ^ Routes as written: name to section ids; the first is the default.
  }
  deriving stock (Eq, Show)

-- | Build from every frame in file order, the sections, and the route definitions.
mkRoutes :: [Text] -> [Section] -> [(Text, [Text])] -> Routes
mkRoutes frames sections = Routes [f | f <- frames, f `notElem` inSections] sections
  where
    inSections = concatMap sectionFrames sections

routeIds :: Routes -> [Text]
routeIds = nub . fmap fst . routesDefs

-- | The first route, if any are defined.
defaultRoute :: Routes -> Maybe Text
defaultRoute = listToMaybe . routeIds

-- | The sections of a route in its order: known ids only, each once. An
-- unknown or absent route means the default route; with no routes defined,
-- every section in file order.
routeSections :: Routes -> Maybe Text -> [Section]
routeSections routes chosen =
  case [ids | name <- [chosen >>= known, defaultRoute routes], Just n <- [name], Just ids <- [lookup n (routesDefs routes)]] of
    ids : _ -> [s | i <- nub ids, s <- take 1 [s | s <- routesSections routes, sectionId s == i]]
    [] -> routesSections routes
  where
    known name = if name `elem` routeIds routes then Just name else Nothing

-- | All frames of a route, in order.
routeFrames :: Routes -> Maybe Text -> [Text]
routeFrames routes chosen = routesLead routes <> concatMap sectionFrames (routeSections routes chosen)

sectionOfFrame :: Routes -> Text -> Maybe Section
sectionOfFrame routes frame = listToMaybe [s | s <- routesSections routes, frame `elem` sectionFrames s]

-- | Where a frame stands on a route: page of pages overall, and within its section.
data Position = Position
  { positionPage :: !Int
  , positionPages :: !Int
  , positionSection :: !(Maybe Section)
  , positionSectionPage :: !Int
  , positionSectionPages :: !Int
  }
  deriving stock (Eq, Show)

-- | One-based position of a frame on a route; 'Nothing' when the route does not
-- contain the frame.
position :: Routes -> Maybe Text -> Text -> Maybe Position
position routes chosen frame = do
  index <- elemIndex frame order
  let section = sectionOfFrame routes frame
      within = maybe 0 (\s -> maybe 0 id (elemIndex frame (sectionFrames s))) section
  Just
    Position
      { positionPage = index + 1
      , positionPages = length order
      , positionSection = section
      , positionSectionPage = within + 1
      , positionSectionPages = maybe 1 (length . sectionFrames) section
      }
  where
    order = routeFrames routes chosen

-- | The first frame after a choice slide on a route: the frame that follows it
-- in the route, or, when the route does not hold the slide, the first frame
-- after the lead.
frameAfterChoice :: Routes -> Text -> Text -> Maybe Text
frameAfterChoice routes route frame =
  case elemIndex frame order of
    Just index -> listToMaybe (drop (index + 1) order)
    Nothing -> listToMaybe (drop (length (routesLead routes)) order)
  where
    order = routeFrames routes (Just route)

-- | A problem with the frontmatter routes.
data RouteIssue
  = UnknownSection !Text !Text
  -- ^ route, section id that no section has (error)
  | MissingSection !Text !Text
  -- ^ route, section the route never visits (warning)
  | DuplicateRoute !Text
  -- ^ route name written twice (error)
  | DuplicateEntry !Text !Text
  -- ^ route, section id listed twice in it (error)
  deriving stock (Eq, Show)

validateRoutes :: [Text] -> [(Text, [Text])] -> [RouteIssue]
validateRoutes sectionIds defs =
  [DuplicateRoute n | n <- dups (fmap fst defs)]
    <> concat
      [ [UnknownSection name i | i <- nub ids, i `notElem` sectionIds]
          <> [DuplicateEntry name i | i <- dups ids]
          <> [MissingSection name s | s <- sectionIds, s `notElem` ids]
      | (name, ids) <- defs
      ]
  where
    dups xs = nub [x | (k, x) <- zip [0 :: Int ..] xs, x `elem` take k xs]

-- | Frames in the order the printed deck shows them: lead, then each section
-- once in default-route order, then any section the default route omits.
exportOrder :: Routes -> [Text]
exportOrder routes = routeFrames routes Nothing <> concat [sectionFrames s | s <- routesSections routes, s `notElem` routeSections routes Nothing]

-- | For a section: each route that continues past it, with the section it goes to next.
continuations :: Routes -> Section -> [(Text, Section)]
continuations routes section =
  [ (name, next)
  | name <- routeIds routes
  , (current : next : _) <- [dropWhile ((/= sectionId section) . sectionId) (routeSections routes (Just name))]
  , sectionId current == sectionId section
  ]
