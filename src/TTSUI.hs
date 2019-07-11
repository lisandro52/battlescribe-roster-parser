{-# LANGUAGE Arrows            #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE RecordWildCards   #-}

module TTSUI where

import           Control.Arrow
import           Data.List
import           Data.Maybe
import           Data.Monoid
import qualified Data.Text          as T
import qualified Data.Text.Encoding as E

import           Crypto.Hash.MD5
import           Data.HexString
import qualified Data.Text.IO
import           Debug.Trace        as Debug
import qualified NeatInterpolation  as NI
import           Safe
import           Text.XML.HXT.Core
import           TTSJson
import           Types
import           XmlHelper

scriptFromXml :: ArrowXml a => String -> a XmlTree String
scriptFromXml name = uiFromXML name >>> arr asScript >>> arr T.unpack

uiFromXML :: ArrowXml a => String -> a XmlTree T.Text
uiFromXML name = (listA (deep (hasName "profile")) &&&
                  (listA (deep (hasName "category")) &&&
                  listA (deep (hasName "cost"))))  >>> profilesToXML name

mapA :: ArrowXml a => a b c -> a [b] [c]
mapA a = listA (unlistA >>> a)

profilesToXML :: ArrowXml a => String -> a ([XmlTree], ([XmlTree], [XmlTree])) T.Text
profilesToXML name = proc (profiles, (categories, costs)) -> do
    categoryTab <- optional (oneCellTable "Categories: ") categoryTable -< categories
    ptsCost <- optional 0 (costsTable "pts") -< costs
    plCost <- optional 0 (costsTable " PL") -< costs
    profileTabs <- inferTables -< profiles
    let costTab = oneCellTable (escapes (T.pack ("Cost: " ++ show ptsCost ++ "pts" ++ " " ++ show plCost ++ " PL")))
    returnA -< masterPanel (T.pack name)  (costTab : categoryTab : filter tableNotEmpty profileTabs)

optional :: ArrowXml a => c -> a b c -> a b c
optional defaultVal a = listA a >>> arr listToMaybe >>> arr (fromMaybe defaultVal)

categoryTable :: ArrowXml a => a [XmlTree] Table
categoryTable = mapA (getAttrValue0 "name")  >>> arr (intercalate ", ") >>> arr (\x -> oneCellTable (escapes (T.pack ("Keywords: " ++ x))))

costsTable :: ArrowXml a => String -> a [XmlTree] Integer
costsTable typeName = mapA (hasAttrValue "name" (== typeName) >>> getAttrValue "value" >>> arr readMay)
    >>> arr catMaybes >>> arr sumOfDoubles >>> arr floor

sumOfDoubles :: [Double] -> Double
sumOfDoubles = sum

tableNotEmpty :: Table -> Bool
tableNotEmpty Table{..} = not (null rows)

stat :: ArrowXml a => String -> a XmlTree T.Text
stat statName = child "characteristics" /> hasAttrValue "name" (== statName) >>> getBatScribeValue >>> arr T.pack

rowFetcher :: ArrowXml a => [a XmlTree T.Text] -> a XmlTree [T.Text]
rowFetcher = catA >>> listA

fetchStats :: ArrowXml a => [String] -> [a XmlTree T.Text]
fetchStats names = getAttrValueT "name" : map stat names

inferTables :: ArrowXml a => a [XmlTree] [Table]
inferTables = proc profiles -> do
    profileTypes <- mapA getType >>> arr nub >>> arr sort -< profiles
    tables <- listA (catA (map inferTable profileTypes)) -<< profiles
    returnA -< tables

inferTable :: ArrowXml a => String -> a [XmlTree] Table
inferTable profileType = proc profiles -> do
    matchingProfiles <-  mapA (isType profileType) -< profiles
    characteristics <- mapA (this /> hasName "characteristics" /> hasName "characteristic" >>> getAttrValue "name") >>> arr nub -<< matchingProfiles
    let header = map T.pack (profileType : characteristics)
    rows <- mapA (rowFetcher (fetchStats characteristics)) -<< matchingProfiles
    let widths = computeWidths (header : rows)
    let sortedUniqueRows = sort (nubBy (\o t -> head o == head t ) rows)
    returnA -< normalTable header sortedUniqueRows widths

bound :: Double -> Double
bound i =  result where
    thresh = 10
    mult = 0.15
    result = if i < thresh then i * 1.5 else thresh + ((i-thresh) * mult)

computeWidths :: [[T.Text]] -> [Double]
computeWidths vals = widths where
    asLengths = map (map (bound . fromIntegral . T.length)) vals :: [[Double]]
    asLineLengths = map maximum (transpose asLengths) :: [Double]
    avg = sum asLineLengths
    widths = map (/ avg) asLineLengths

asScript :: T.Text -> T.Text
asScript uiRaw = [NI.text|

function onLoad()
  Wait.frames(
    function()
      self.setVar("bs2tts-model", true)
      local id = "bs2tts-ui-load"
      loadUI()
      Timer.destroy(id)
      Timer.create(
        {
          identifier = id,
          function_name = "loadUIs",
          parameters = {},
          delay = 2
        }
      )
    end,
  2)
end

function loadUIs()
  local uistring = Global.getVar("bs2tts-ui-string")
  UI.setXml(UI.getXml() .. uistring)
end

function createUI(uiId, playerColor)
  local guid = self.getGUID()
  local uiString = string.gsub(
                   string.gsub(
                   string.gsub([[ $ui ]], "thepanelid", uiId ),
                                          "theguid", guid),
                                          "thecolor", playerColor)
  print(uiString)
                                          return uiString
end

function loadUI()
  local totalUI = ""
  for k, color in pairs(Player.getColors()) do
    totalUI = totalUI .. createUI(createName(color), color)
  end
  local base = ""
  if Global.getVar("bs2tts-ui-string") then
    base = Global.getVar("bs2tts-ui-string")
  end
  Global.setVar("bs2tts-ui-string", base .. totalUI)
end

function onScriptingButtonDown(index, peekerColor)
  local player = Player[peekerColor]
  local name = createName(peekerColor)
  if index == 1 and player.getHoverObject() and player.getHoverObject().getDescription() == self.getDescription() then
    UI.show(name)
  end
end

function closeUI(player, val, id)
  local peekerColor = player.color
  UI.hide(createName(peekerColor))
end

function grow(player, val, id)
  local peekerColor = player.color
  local panelId = createName(peekerColor)
  print("Grow "..panelId)
  UI.setAttribute(panelId, "scale", "")
end

function shrink(player, val, id)
  local peekerColor = player.color
  local panelId = createName(peekerColor)
  print("Shrink "..panelId)
  UI.setAttribute(panelId, "scale", "0.8 0.8")
end

function createName(color)
  local guid = self.getGUID()
  return (guid .. "-" .. color)
end

|] where
    ui = uiRaw

escape :: Char -> String -> String -> String
escape target replace (c : s) = if c == target then replace ++ escape target replace s else c : escape target replace s
escape _ _ [] = []

escapeT :: Char -> String -> T.Text -> T.Text
escapeT c s = T.pack . escape c s . T.unpack

escapes :: T.Text -> T.Text
escapes = escapeT '"' "&quot;" .
  escapeT '<' "&lt;" . escapeT '>' "&gt;"
  . escapeT '\'' "&apos;"
  . escapeT '\n' "&#xD;&#xA;"

masterPanel :: T.Text -> [Table] -> T.Text
masterPanel name tables = [NI.text|
    <Panel id="thepanelid" visibility="thecolor" active="false" width="$width" height="$height" returnToOriginalPositionWhenReleased="false" allowDragging="true" color="#FFFFFF" childForceExpandWidth="false" childForceExpandHeight="false">
    <TableLayout autoCalculateHeight="true" width="$width" childForceExpandWidth="false" childForceExpandHeight="false">
    <Row preferredHeight="40">
    <Text fontSize="25" rectAlignment="MiddleCenter" text="$name" width="$width"/>
    <HorizontalLayout rectAlignment="UpperRight" height="40" width="120">
    <Button id="theguid-grow" class="topButtons"  color="#990000" textColor="#FFFFFF" text="+" height="40" width="40" onClick="theguid/grow" />
    <Button id="theguid-shrink" class="topButtons"  color="#990000" textColor="#FFFFFF" text="-" height="40" width="40" onClick="theguid/shrink" />
    <Button id="theguid-close" class="topButtons"  color="#990000" textColor="#FFFFFF" text="X" height="40" width="40" onClick="theguid/closeUI" />
    </HorizontalLayout>
    </Row>
    <Row preferredHeight="$scrollHeight">
    <VerticalScrollView scrollSensitivity="30" height="$scrollHeight" width="$width">
    <TableLayout padding="10" cellPadding="5" horizontalOverflow="Wrap" columnWidths="$width" autoCalculateHeight="true">
    $tableXml
    </TableLayout>
    </VerticalScrollView>
    </Row>
    </TableLayout>
    </Panel> |] where
        heightN = 600
        height = numToT heightN
        scrollHeight = numToT (heightN - 40)
        widthN = 900
        width = numToT widthN
        tableXml = mconcat $ map (tableToXml widthN) tables

data Table = Table {
    columnWidthPercents :: [Double],
    headerHeight        :: Integer,
    textSize            :: Integer,
    headerTextSize      :: Integer,
    header              :: [T.Text],
    rows                :: [[T.Text]]
} deriving Show

oneCellTable header = Table [1] 40 15 20 [header] []
oneRowTable header row = Table [1] 40 15 20 [header] [[row]]
normalTable header rows widths = Table widths 40 18 20 header rows

numToT :: Integer -> T.Text
numToT = T.pack . show

inferRowHeight :: [T.Text] -> Integer
inferRowHeight = maximum . map inferCellHeight

inferCellHeight :: T.Text -> Integer
inferCellHeight t = maximum [(tLen `quot` 80 + newlines) * 20, 80] where
  newlines = fromIntegral (T.count "\n" t)
  tLen = fromIntegral $ T.length t

tableToXml :: Integer -> Table -> T.Text
tableToXml tableWidth Table{..} = [NI.text|
  <Row preferredHeight="$tableHeight">
    <TableLayout autoCalculateHeight="false" cellPadding="5" columnWidths="$colWidths">
        $headerText
        $bodyText
    </TableLayout>
  </Row>
|] where
    rowHeights = map inferRowHeight rows
    tableHeight = numToT $ headerHeight + sum rowHeights
    colWidths = T.intercalate " " $ map (numToT . floor . (* fromIntegral tableWidth)) columnWidthPercents
    headHeight = numToT headerHeight
    tSize = numToT textSize
    htSize = numToT headerTextSize
    headerText = tRow htSize "Bold" headHeight header
    rowsAndHeights = zip rowHeights rows
    bodyText = mconcat $ map (\(height, row) -> (tRow tSize "Normal" (numToT height) . map escapes) row) rowsAndHeights

tCell :: T.Text -> T.Text -> T.Text -> T.Text
tCell fs stl val = [NI.text| <Cell><Text resizeTextForBestFit="true" resizeTextMaxSize="$fs" resizeTextMinSize="6"
  text="$val" fontStyle="$stl" fontSize="$fs"/></Cell> |]

tRow :: T.Text -> T.Text -> T.Text -> [T.Text] -> T.Text
tRow fs stl h vals = "<Row flexibleHeight=\"1\" preferredHeight=\"" <> h <> "\">" <> mconcat (map (tCell fs stl) vals) <> "</Row>"

child :: ArrowXml a => String -> a XmlTree XmlTree
child tag = getChildren >>> hasName tag

getAttrValueT :: ArrowXml a => String -> a XmlTree T.Text
getAttrValueT attr = getAttrValue attr >>> arr T.pack