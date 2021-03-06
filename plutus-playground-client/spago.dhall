{-
Welcome to a Spago project!
You can edit this file as you like.
-}
{ name = "plutus-playground-client"
, dependencies =
  [ "aff"
  , "affjax"
  , "argonaut-codecs"
  , "argonaut-core"
  , "arrays"
  , "bifunctors"
  , "console"
  , "control"
  , "coroutines"
  , "dom-indexed"
  , "effect"
  , "either"
  , "enums"
  , "exceptions"
  , "foldable-traversable"
  , "foreign-object"
  , "gen"
  , "halogen"
  , "http-methods"
  , "integers"
  , "json-helpers"
  , "lists"
  , "matryoshka"
  , "maybe"
  , "media-types"
  , "newtype"
  , "node-buffer"
  , "node-fs"
  , "nonempty"
  , "ordered-collections"
  , "prelude"
  , "profunctor-lenses"
  , "psci-support"
  , "quickcheck"
  , "remotedata"
  , "servant-support"
  , "spec"
  , "spec-quickcheck"
  , "strings"
  , "tailrec"
  , "transformers"
  , "tuples"
  , "web-common"
  , "web-events"
  , "web-html"
  , "web-uievents"
  ]
, packages = ../packages.dhall
, sources =
  [ "src/**/*.purs"
  , "test/**/*.purs"
  , "generated/**/*.purs"
  , "../web-common-plutus/src/**/*.purs"
  , "../web-common-playground/src/**/*.purs"
  ]
}
