module Editor.View
  ( editorPreferencesSelect
  , compileButton
  , simulateButton
  , editorPane
  , editorFeedback
  ) where

import Prologue hiding (div)
import AjaxUtils (ajaxErrorPane)
import Bootstrap (btn, card, cardHeader, cardHeader_, cardBody_, customSelect, empty, listGroupItem_, listGroup_, nbsp)
import Data.Array as Array
import Data.Lens (_Right, preview, to, view)
import Data.Maybe (fromMaybe, maybe)
import Data.String as String
import Editor.Lenses (_warnings)
import Editor.State (initEditor)
import Editor.Types (Action(..), State(..), allKeyBindings)
import Effect.Aff.Class (class MonadAff)
import Halogen.HTML (ClassName(ClassName), ComponentHTML, HTML, a, button, code_, div, div_, option, p_, pre, pre_, select, slot, text)
import Halogen.HTML.Events (onClick, onDragOver, onDrop, onMouseDown, onMouseMove, onMouseUp, onSelectedIndexChange)
import Halogen.HTML.Properties (class_, classes, disabled, id, selected, value)
import Halogen.Monaco (KeyBindings(..), monacoComponent)
import Icons (Icon(..), icon)
import Language.Haskell.Interpreter (CompilationError(CompilationError, RawError), InterpreterError(CompilationErrors, TimeoutError), Warning, _InterpreterResult, _Warning)
import Language.Haskell.Monaco as HM
import LocalStorage (Key)
import MainFrame.Lenses (_editorSlot)
import MainFrame.Types (ChildSlots, HAction(..), View(..), WebCompilationResult)
import Network.RemoteData (RemoteData(..), _Success, isLoading)
import Web.UIEvent.MouseEvent (MouseEvent, pageY)

editorPreferencesSelect :: forall p. KeyBindings -> HTML p Action
editorPreferencesSelect active =
  select
    [ class_ customSelect
    , onSelectedIndexChange $ maybe DoNothing SetKeyBindings <<< Array.index allKeyBindings
    ]
    (editor <$> allKeyBindings)
  where
  editor keyBindings =
    option
      [ value $ show keyBindings
      , selected (active == keyBindings)
      ]
      [ text $ editorName keyBindings ]

  editorName DefaultBindings = "Default"

  editorName Emacs = "Emacs"

  editorName Vim = "Vim"

compileButton :: forall p. WebCompilationResult -> HTML p HAction
compileButton compilationResult =
  button
    [ classes [ btn, ClassName "btn-green" ]
    , onClick $ const CompileProgram
    , disabled (isLoading compilationResult)
    ]
    [ btnText ]
  where
  btnText = case compilationResult of
    Loading -> icon Spinner
    _ -> text "Compile"

simulateButton :: forall p. Boolean -> WebCompilationResult -> HTML p HAction
simulateButton currentCodeIsCompiled compilationResult =
  button
    [ classes [ btn, ClassName "btn-turquoise" ]
    , onClick $ const $ ChangeView Simulations
    , disabled isDisabled
    ]
    [ text "Simulate" ]
  where
  isDisabled = case compilationResult of
    Success (Right _) -> not currentCodeIsCompiled
    _ -> true

editorPane :: forall m. MonadAff m => Maybe String -> Key -> State -> ComponentHTML Action ChildSlots m
editorPane initialContents bufferLocalStorageKey editorState@(State { keyBindings }) =
  div
    [ class_ (ClassName "code-editor")
    , onDragOver HandleDragEvent
    , onDrop HandleDropEvent
    -- This is not the natural place to have these listeners. But see note [1] below.
    , onMouseMove feedbackPaneResizeMouseMoveHandler
    , onMouseUp feedbackPaneResizeMouseUpHandler
    ]
    [ slot
        _editorSlot
        unit
        (monacoComponent (HM.settings (initEditor initialContents bufferLocalStorageKey editorState)))
        unit
        HandleEditorMessage
    , case keyBindings of
        Vim -> pre [ id "statusline" ] [ nbsp ]
        _ -> pre [ id "statusline", class_ $ ClassName "hidden" ] [ nbsp ]
    ]

editorFeedback :: forall p. State -> WebCompilationResult -> HTML p Action
editorFeedback (State { currentCodeIsCompiled, feedbackPaneExtend, feedbackPaneMinimised }) compilationResult =
  div
    [ class_ $ ClassName "editor-feedback-container"
    -- This is also not the natural place to have these listeners. But see note [1] below.
    , onMouseMove feedbackPaneResizeMouseMoveHandler
    , onMouseUp feedbackPaneResizeMouseUpHandler
    ]
    [ div
        [ classes feedbackPaneClasses ]
        [ div
            [ class_ $ ClassName "editor-feedback-resize-bar"
            , onMouseDown SetFeedbackPaneDragStart
            -- Note [1]: This is the natural place to have these listeners. But because the mouse
            -- can - and probably will - move faster than this resize bar, they also need to be on
            -- the editor pane (to catch when the mouse moves up faster), and on the feedback
            -- container (to catch when the mouse moves down faster).
            , onMouseMove feedbackPaneResizeMouseMoveHandler
            , onMouseUp feedbackPaneResizeMouseUpHandler
            ]
            (if feedbackPaneMinimised then [] else [ nbsp ])
        , div
            [ class_ $ ClassName "editor-feedback-header" ]
            [ p_ [ summaryText ]
            , case compilationResult of
                Success (Left _) -> minMaxButton
                Failure _ -> minMaxButton
                _ -> empty
            ]
        , div
            [ class_ $ ClassName "editor-feedback-body" ]
            [ errorList
            , warningList
            ]
        ]
    ]
  where
  feedbackPaneClasses =
    [ ClassName "editor-feedback" ]
      <> case feedbackPaneMinimised, feedbackPaneExtend of
          false, 0 -> []
          true, 0 -> [ ClassName "minimised" ]
          false, size -> [ ClassName $ "expanded-" <> show size ]
          true, size -> [ ClassName "minimised", ClassName $ "expanded-" <> show size ]

  summaryText = case compilationResult of
    NotAsked -> text "Not compiled"
    Loading -> text "Compiling ..."
    Success (Left _) -> text "Compilation failed"
    Failure _ -> text "Compilation failed"
    _ ->
      if currentCodeIsCompiled then
        text "Compilation successful"
      else
        text "Code changed since last compilation"

  minMaxButton =
    a
      [ class_ btn
      , onClick $ const ToggleFeedbackPane
      ]
      [ icon
          $ if feedbackPaneMinimised then
              ArrowUp
            else
              ArrowDown
      ]

  errorList = case compilationResult of
    Success (Left error) -> listGroup_ (interpreterErrorPane error)
    Failure error -> ajaxErrorPane error
    _ -> empty

  warningList =
    fromMaybe empty
      $ preview
          ( _Success
              <<< _Right
              <<< _InterpreterResult
              <<< _warnings
              <<< to compilationWarningsPane
          )
          compilationResult

feedbackPaneResizeMouseMoveHandler :: MouseEvent -> Action
feedbackPaneResizeMouseMoveHandler event = FixFeedbackPaneExtend $ pageY event

feedbackPaneResizeMouseUpHandler :: MouseEvent -> Action
feedbackPaneResizeMouseUpHandler = const ClearFeedbackPaneDragStart

interpreterErrorPane :: forall p. InterpreterError -> Array (HTML p Action)
interpreterErrorPane (TimeoutError error) = [ listGroupItem_ [ div_ [ text error ] ] ]

interpreterErrorPane (CompilationErrors errors) = map compilationErrorPane errors

compilationErrorPane :: forall p. CompilationError -> HTML p Action
compilationErrorPane (RawError error) =
  div
    [ classes [ card, ClassName "raw-error" ] ]
    [ cardHeader_ [ text "Compilation Error" ]
    , cardBody_ [ text error ]
    ]

compilationErrorPane (CompilationError error) =
  div
    [ classes [ card, ClassName "compilation-error" ] ]
    [ div
        [ class_ cardHeader ]
        [ text $ "Compilation Error, Line " <> show error.row <> ", Column " <> show error.column
        , nbsp
        , a
            [ onClick $ const $ ScrollTo { lineNumber: error.row, column: error.column } ]
            [ text "(jump)" ]
        ]
    , cardBody_
        [ code_ [ pre_ [ text $ String.joinWith "\n" error.text ] ] ]
    ]

compilationWarningsPane :: forall p. Array Warning -> HTML p Action
compilationWarningsPane warnings = listGroup_ (listGroupItem_ <<< pure <<< compilationWarningPane <$> warnings)

compilationWarningPane :: forall p. Warning -> HTML p Action
compilationWarningPane warning = div [ class_ $ ClassName "compilation-warning" ] [ text $ view _Warning warning ]
