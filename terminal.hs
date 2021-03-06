{-# LANGUAGE PackageImports, OverloadedStrings, DataKinds, TypeOperators #-}
{-# LANGUAGE ViewPatterns, FlexibleContexts #-}

import Control.Applicative ((<$>))
import Control.Arrow
import Control.Monad
import Control.Monad.Fix
import Data.Time.Clock
import qualified Data.Trie as T
import qualified Data.Vector.Storable as SV
import Graphics.Text.TrueType
import qualified Graphics.UI.GLFW as GLFW
import LambdaCube.Font.Atlas
import LambdaCube.Font.Common
import qualified LambdaCube.Font.SimpleDistanceField as SDF
import qualified LambdaCube.Font.CompositeDistanceField as CDF
import LambdaCube.GL
import LambdaCube.GL.Mesh
import System.Environment
import System.Exit
import Data.Vect
import Data.Maybe
import qualified Data.Vector.Storable as Vec

import Data.IORef
import Data.Char

useCompositeDistanceField = True

textStyle = defaultTextStyle { textLetterSpacing = 0.0, textLineHeight = 1.25 }
fontOptions = defaultOptions { atlasSize = 1024, atlasLetterPadding = 2 }

toVec3 :: V3F -> Vec3
toVec3 (V3 a b c) = Vec3 a b c

toMat3 :: M33F -> Mat3
toMat3 (V3 a b c) = Mat3 (toVec3 a) (toVec3 b) (toVec3 c)

fromVec3 :: Vec3 -> V3F
fromVec3 (Vec3 a b c) = V3 a b c

fromMat3 :: Mat3 -> M33F
fromMat3 (Mat3 a b c) = V3 (fromVec3 a) (fromVec3 b) (fromVec3 c)

rotMatrix :: Float -> Mat3
rotMatrix a = Mat3 (Vec3 c s 0) (Vec3 (-s) c 0) (Vec3 0 0 1) where c = cos a; s = sin a


main = do
    {-
    args <- getArgs
    when (null args) $ do
        putStrLn "Usage: HelloWorld <ttf-file> [<pixels-per-em>]"
        exitSuccess
    -}
    --let args = ["unicodefonts/DejaVuSans.ttf"]
    let args = ["unicodefonts/Ubuntu-Regular.ttf"]
    GLFW.init
    GLFW.defaultWindowHints
    mapM_ GLFW.windowHint
      [ GLFW.WindowHint'ContextVersionMajor 3
      , GLFW.WindowHint'ContextVersionMinor 3
      , GLFW.WindowHint'OpenGLProfile GLFW.OpenGLProfile'Core
      , GLFW.WindowHint'OpenGLForwardCompat True
      ]
    Just win <- GLFW.createWindow 1024 768 "LambdaCube 3D Text Demo" Nothing Nothing
    GLFW.makeContextCurrent $ Just win

    renderer <- compileRenderer (ScreenOut (PrjFrameBuffer "" tix0 testRender))
    setScreenSize renderer 1024 768

    Right font <- loadFontFile (head args)
    let fontRenderer = if useCompositeDistanceField then CDF.fontRenderer else SDF.fontRenderer
        letterScale = if length args > 1 then read (args !! 1) else 72
    atlas <- createFontAtlas font fontRenderer fontOptions { atlasLetterScale = letterScale }

    let printText :: ((String, String), Int) -> IO Object
        printText ((xs, ys), e) = do
          let col i (splitAt i -> (as, bs)) = map ((,) (V4 0 0 0 0, V4 0 1 0 1)) as ++ map ((,) (V4 0 0 0 0, V4 1 1 1 1)) bs
              txt_ = reverse (col (max 0 $ negate e) xs) ++ ((V4 0 0 0 0, V4 1 0 0 1), '|') : col (max 0 e) ys
              txt = map snd txt_
          textMesh_ <- buildTextMesh atlas textStyle txt
          let Just (A_V2F pos) = T.lookup "position" $ mAttributes textMesh_
              hackSize c
                 | c `elem` (":;\"éáűőú≤≥" :: String) = 2
                 | isSpace c = 0
                 | otherwise = 1
              hack t@(_, c) = replicate (hackSize c) t
              bs = take (Vec.length pos) $ map fst (concatMap (replicate 6) $ concatMap hack txt_) ++ repeat (V4 0 0 0 0, V4 1 1 1 1)
              colors = Vec.fromList $ map snd bs
              background = Vec.fromList $ map fst bs
              textMesh = textMesh_ { mAttributes = T.insert "color" (A_V4F colors) $ T.insert "background" (A_V4F background) $ mAttributes textMesh_ }
          textBuffer <- compileMesh textMesh
          addMesh renderer "textMesh" textBuffer []

        txt0 = (\s -> ((reverse s, ""), 0 :: Int)) $ unlines []
        agdaChars =
                [ "01-02-03-04-05-07-08-09-10-11-12-13-14-15-16-17-18-19-20-21-22-23-24-25-26-27-28-29-30"
                , "→➡⊎×⋆∷∘∨∧⊔⊓"
                , "∀∃"
                , "⟦⟧⟨⟩"
                , "₁₂₃₄₅₆₇₈₉₀"
                , "≡≤≥≟"
                , "⊤⊥ℕℤℚλαβγΓ"
                , "′″‴⁗"
                ]
    txtObj0 <- printText txt0

    editState <- newIORef (txt0,txtObj0)

    let uniforms = uniformSetter renderer
        letterScale = atlasLetterScale (atlasOptions atlas)
        letterPadding = atlasLetterPadding (atlasOptions atlas)
    uniformFTexture2D "fontAtlas" uniforms (getTextureData atlas)

    -- adding character to string
    GLFW.setCharCallback win $ Just $ \_ c -> do
      rAlt <- (==GLFW.KeyState'Pressed) <$> GLFW.getKey win GLFW.Key'RightAlt
      rCtrl <- (==GLFW.KeyState'Pressed) <$> GLFW.getKey win GLFW.Key'LeftControl
      when (isPrint c && not rAlt && not rCtrl) $ do
        (((as,bs), sel_),txtObj) <- readIORef editState
        let txt' = ((c:) *** id $ delSel (as, bs), 0)

            delSel (as, bs) = (when_ (sel_ < 0) (drop $ negate sel_) as, when_ (sel_ > 0) (drop sel_) bs)
        txtObj' <- printText txt'
        removeObject renderer txtObj
        writeIORef editState (txt',txtObj')

    -- handle control buttons e.g. backspace
    GLFW.setKeyCallback win $ Just $ \_ k sc ks mk -> do
      alt <- (==GLFW.KeyState'Pressed) <$> GLFW.getKey win GLFW.Key'RightAlt
      when (ks == GLFW.KeyState'Pressed || ks == GLFW.KeyState'Repeating) $ do
        clipboard <- GLFW.getClipboardString win
        (tx@(txt, sel_), txtObj) <- readIORef editState
        let (txt', clipboard') = f k txt

            noSel x = ((x, 0), Nothing)
            sel s x
                | not shift = noSel x
                | otherwise = ((x, s + sel_), Nothing)
            shift = GLFW.modifierKeysShift mk

            delSel (as, bs) = (when_ (sel_ < 0) (drop $ negate sel_) as, when_ (sel_ > 0) (drop sel_) bs)
            getSel (as, bs) = if sel_ == 0 then Nothing else Just (if sel_ < 0 then reverse $ take (negate sel_) as else take sel_ bs)

            f GLFW.Key'Enter     (as, bs)        = noSel ('\n': as, bs)
            f GLFW.Key'Backspace (as, bs) | sel_ /= 0 = noSel $ delSel (as, bs)
            f GLFW.Key'Backspace (_: as, bs)     = noSel (as, bs)
            f GLFW.Key'Delete    (as, bs) | sel_ /= 0 = noSel $ delSel (as, bs)
            f GLFW.Key'Delete    (as, _: bs)     = noSel (as, bs)
            f GLFW.Key'Left      (a: as, bs) | not alt    = sel   1  (as, a: bs)
            f GLFW.Key'Left      (as, bs) | not shift && not alt       = noSel (as, bs)
            f GLFW.Key'Right     (as, b: bs) | not alt     = sel (-1) (b: as, bs)
            f GLFW.Key'Right     (as, bs) | not shift && not alt       = noSel (as, bs)
            f GLFW.Key'Up        (findChar '\n' -> Just (cs, as), bs) | not alt
                = sel (length $ '\n': reverse cs) (as, '\n': reverse cs ++ bs)
            f GLFW.Key'Up        (as, bs) | not shift && not alt       = noSel (as, bs)
            f GLFW.Key'Down      (as, findChar '\n' -> Just (cs, bs)) | not alt
                = sel (negate $ length $ '\n': reverse cs) ('\n': reverse cs ++ as, bs)
            f GLFW.Key'Down      (as, bs) | not shift && not alt       = noSel (as, bs)
            f GLFW.Key'A (as, bs)  | GLFW.modifierKeysControl mk = (((reverse bs ++ as, ""), negate $ length $ reverse bs ++ as), Nothing)
            f GLFW.Key'X (as, bs)  | GLFW.modifierKeysControl mk
                = ((delSel (as, bs), 0)
                    , getSel (as, bs))
            f GLFW.Key'C (as, bs)  | GLFW.modifierKeysControl mk
                = (((as, bs), sel_), getSel (as, bs))
            f GLFW.Key'V (as, bs)  | GLFW.modifierKeysControl mk
                = noSel ((reverse (fromMaybe "" clipboard) ++) *** id $ delSel (as, bs))
            f _             _               = (tx, Nothing)
        txtObj' <- if tx /= txt'
            then do
              removeObject renderer txtObj
              printText txt'
            else return txtObj
        maybe (return ()) (GLFW.setClipboardString win) clipboard'
        writeIORef editState (txt', txtObj')

    startTime <- getCurrentTime
    flip fix (startTime, V2 (-0.98846203) 0.7812101,0.2,0.0) $ \loop (prevTime, V2 ofsX ofsY, scale, angle) -> do
        uniformM33F "textTransform" uniforms $ fromMat3 $ rotMatrix angle .*. toMat3 (V3 (V3 (scale * 0.75) 0 0) (V3 0 scale 0) (V3 ofsX ofsY 1))
        uniformFloat "outlineWidth" uniforms (min 0.5 (fromIntegral letterScale / (768 * fromIntegral letterPadding * scale * sqrt 2 * 0.75)))
        render renderer
        GLFW.swapBuffers win
        GLFW.pollEvents
        escPressed <- (==GLFW.KeyState'Pressed) <$> GLFW.getKey win GLFW.Key'Escape

        curTime <- getCurrentTime
        let dt = realToFrac (diffUTCTime curTime prevTime) :: Float
        rAlt <- (==GLFW.KeyState'Pressed) <$> GLFW.getKey win GLFW.Key'RightAlt
        [left, right, up, down, zoomIn, zoomOut, rotLeft, rotRight] <- map ((rAlt &&).(==GLFW.KeyState'Pressed)) <$> mapM (GLFW.getKey win) [GLFW.Key'Left, GLFW.Key'Right, GLFW.Key'Up, GLFW.Key'Down, GLFW.Key'Q, GLFW.Key'A, GLFW.Key'W, GLFW.Key'S]
        let inputX = (if right then -1 else 0) + (if left then 1 else 0)
            inputY = (if up then -1 else 0) + (if down then 1 else 0)
            inputScale = (if zoomOut then -1 else 0) + (if zoomIn then 1 else 0)
            inputAngle = (if rotLeft then -1 else 0) + (if rotRight then 1 else 0)
            scaleChange = (1 + dt) ** inputScale
            angle' = angle + inputAngle * dt * 2
            scale' = scale * scaleChange
            ofsX' = ofsX * scaleChange + inputX * dt * 2
            ofsY' = ofsY * scaleChange + inputY * dt * 2
        unless escPressed (loop (curTime, V2 ofsX' ofsY', scale', angle'))

    GLFW.destroyWindow win
    GLFW.terminate

testRender :: Exp Obj (FrameBuffer 1 V4F)
testRender = renderText emptyBuffer
  where
    renderText = Accumulate textFragmentCtx PassAll textFragmentShader textFragmentStream
    emptyBuffer = FrameBuffer (ColorImage n1 (V4 0 0 0 1) :. ZT)
    rasterCtx = TriangleCtx CullNone PolygonFill NoOffset LastVertex

    textFragmentCtx = AccumulationContext Nothing (ColorOp textBlending (V4 True True True True) :. ZT)
    textBlending = Blend (FuncAdd, FuncAdd) ((One, One), (OneMinusSrcAlpha, One)) zero'
    textFragmentStream = Rasterize rasterCtx textStream
    textStream = Transform vertexShader (Fetch "textMesh" Triangles (IV2F "position", IV2F "uv", IV4F "color", IV4F "background"))

    vertexShader attr = VertexOut point (floatV 1) ZT (Smooth uv :. Smooth color :. Smooth background :. ZT)
      where
        point = v3v4 (transform @*. v2v3 pos)
        transform = Uni (IM33F "textTransform") :: Exp V M33F
        (pos, uv, color, background) = untup4 attr

    textFragmentShader (untup3 -> (uv, color, background)) = FragmentOut (char :. ZT)
      where
        char = color @* pack' (V4 result result result result) @+ background @* (floatF 1 @- result)
        result = step distance
        distance = case useCompositeDistanceField of
            False -> SDF.sampleDistance "fontAtlas" uv
            True -> CDF.sampleDistance "fontAtlas" uv
        step = smoothstep' (floatF 0.5 @- outlineWidth) (floatF 0.5 @+ outlineWidth)
        outlineWidth = Uni (IFloat "outlineWidth") :: Exp F Float

when_ b f = if b then f else id

findChar c [] = Nothing
findChar c (x:xs)
    | x==c = Just ([], xs)
    | otherwise = ((x:) *** id) <$> findChar c xs


