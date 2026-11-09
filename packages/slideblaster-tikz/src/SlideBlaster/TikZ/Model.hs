-- |
-- Module      : SlideBlaster.TikZ.Model
-- Description : Validated semantic picture values for the literal Slice 1 subset.
--
-- The model contains meaning only: one named content node, one direct point,
-- and one straight connector. Concrete spelling and edit provenance stay with
-- the document snapshot.
module SlideBlaster.TikZ.Model
  ( Connector
  , Coordinate
  , CoordinateError (..)
  , Node
  , NodeId
  , Picture
  , Point
  , connectorEnd
  , connectorStart
  , coordinateFromDecimalText
  , coordinateFromInteger
  , coordinateFromScaled
  , coordinateFromRational
  , coordinateToText
  , mkNodeId
  , nodeContent
  , nodeId
  , nodeIdText
  , nodePosition
  , pictureConnector
  , pictureNode
  , point
  , pointX
  , pointY
  ) where

import Data.Text (Text)
import SlideBlaster.TikZ.Internal.Decimal
  ( Coordinate
  , CoordinateError (..)
  , coordinateFromDecimalText
  , coordinateFromInteger
  , coordinateFromScaled
  , coordinateFromRational
  , coordinateToText
  )
import SlideBlaster.TikZ.Internal.Types
  ( Connector (..)
  , Node (..)
  , NodeId
  , Picture (..)
  , Point (..)
  , mkNodeId
  , nodeIdText
  )

-- | Construct a semantic point from validated decimal coordinates.
point :: Coordinate -> Coordinate -> Point
point = Point

-- | Return the horizontal coordinate.
pointX :: Point -> Coordinate
pointX (Point value _) = value

-- | Return the vertical coordinate.
pointY :: Point -> Coordinate
pointY (Point _ value) = value

-- | Return the node identity.
nodeId :: Node -> NodeId
nodeId (Node value _ _) = value

-- | Return the direct semantic node position.
nodePosition :: Node -> Point
nodePosition (Node _ value _) = value

-- | Return decoded UTF-8 node content.
nodeContent :: Node -> Text
nodeContent (Node _ _ value) = value

-- | Return the connector's named start node.
connectorStart :: Connector -> NodeId
connectorStart (Connector value _) = value

-- | Return the connector's absolute endpoint.
connectorEnd :: Connector -> Point
connectorEnd (Connector _ value) = value

-- | Return the picture's only node.
pictureNode :: Picture -> Node
pictureNode (Picture value _) = value

-- | Return the picture's only connector.
pictureConnector :: Picture -> Connector
pictureConnector (Picture _ value) = value
