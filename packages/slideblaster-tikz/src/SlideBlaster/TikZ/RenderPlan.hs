-- |
-- Module      : SlideBlaster.TikZ.RenderPlan
-- Description : Renderer-neutral instructions derived from a ready picture.
--
-- The plan resolves the connector start from the node's current semantic
-- position each time. It contains no source authority, DOM values, or
-- persistence state.
module SlideBlaster.TikZ.RenderPlan
  ( RenderConnector
  , RenderError (..)
  , RenderNode
  , RenderPlan
  , renderConnectorEnd
  , renderConnectorStart
  , renderDocument
  , renderNodeContent
  , renderNodeStructuredContent
  , renderNodeId
  , renderNodePosition
  , renderPlanConnector
  , renderPlanNode
  ) where

import Data.Text (Text)
import SlideBlaster.TikZ.Internal.Types
  ( AnalysisState (..)
  , Connector (..)
  , DocumentSnapshot
  , Node (..)
  , NodeId
  , Picture (..)
  , Point
  , ReadyDocument (..)
  , RenderConnector (..)
  , RenderError (..)
  , RenderNode (..)
  , RenderPlan (..)
  , documentAnalysis
  )
import SlideBlaster.TikZ.NodeContent (NodeContent, readNodeContent)

-- | Derive the minimal drawing and interaction plan.
renderDocument :: DocumentSnapshot -> Either RenderError RenderPlan
renderDocument document =
  case documentAnalysis document of
    AnalysisUnavailable diagnostics ->
      Left (RenderSemanticsUnavailable diagnostics)
    AnalysisReady
      ( ReadyDocument
          (Picture (Node nodeId nodePoint content) (Connector _ endpoint))
          _
          _
        ) ->
        Right
          ( RenderPlan
              (RenderNode nodeId nodePoint content (readNodeContent content))
              (RenderConnector nodePoint endpoint)
          )

-- | Return the positioned content-node instruction.
renderPlanNode :: RenderPlan -> RenderNode
renderPlanNode (RenderPlan value _) = value

-- | Return the straight connector instruction.
renderPlanConnector :: RenderPlan -> RenderConnector
renderPlanConnector (RenderPlan _ value) = value

-- | Return the render identity.
renderNodeId :: RenderNode -> NodeId
renderNodeId (RenderNode value _ _ _) = value

-- | Return the node centre.
renderNodePosition :: RenderNode -> Point
renderNodePosition (RenderNode _ value _ _) = value

-- | Return the exact authored node content.
renderNodeContent :: RenderNode -> Text
renderNodeContent (RenderNode _ _ value _) = value

-- | Return the interpreted node content: resolved runs and their status.
renderNodeStructuredContent :: RenderNode -> NodeContent
renderNodeStructuredContent (RenderNode _ _ _ value) = value

-- | Return the resolved connector start.
renderConnectorStart :: RenderConnector -> Point
renderConnectorStart (RenderConnector value _) = value

-- | Return the absolute connector end.
renderConnectorEnd :: RenderConnector -> Point
renderConnectorEnd (RenderConnector _ value) = value
