{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Language.Iris.Validation.Query.Fragment
  ( validateFragments,
    castFragmentType,
    validateFragment,
    selectFragmentType,
    ValidateFragmentSelection,
    validateSpread,
  )
where

import Control.Monad.Except (throwError)
import Data.Mergeable.Utils
  ( Empty (empty),
  )
import Language.Iris.Error.Selection
  ( cannotBeSpreadOnType,
  )
import Language.Iris.Types.Internal.AST
  ( Directives,
    Fragment (..),
    FragmentName,
    Fragments,
    OBJECT,
    Position,
    RAW,
    Ref (..),
    SelectionSet,
    Stage,
    TypeDefinition,
    TypeName,
    UnionTag (..),
    VALID,
  )
import Language.Iris.Types.Internal.Validation
  ( Constraint (..),
    FragmentValidator,
    askFragments,
    constraint,
    selectKnown,
    setPosition, withScope,
  )
import Language.Iris.Types.Internal.Validation.Internal
import Relude hiding (empty)

class ValidateFragmentSelection (s :: Stage) where
  validateFragmentSelection ::
    Applicative m =>
    (Fragment RAW -> m (SelectionSet VALID)) ->
    Fragment s ->
    m (SelectionSet VALID)

instance ValidateFragmentSelection VALID where
  validateFragmentSelection _ = pure . fragmentSelection

instance ValidateFragmentSelection RAW where
  validateFragmentSelection f = f

validateSpread ::
  ValidateFragmentSelection s =>
  (Fragment RAW -> FragmentValidator s (SelectionSet VALID)) ->
  [TypeName] ->
  Ref FragmentName ->
  FragmentValidator s UnionTag
validateSpread f allowedTargets ref = do
  fragment@Fragment {fragmentType} <- resolveSpread allowedTargets ref
  UnionTag fragmentType <$> validateFragmentSelection f fragment

validateFragment ::
  (Fragment RAW -> FragmentValidator s (SelectionSet VALID)) ->
  [TypeName] ->
  Fragment RAW ->
  FragmentValidator s (Fragment VALID)
validateFragment validate allowedTypes fragment@Fragment {fragmentPosition} =
  castFragmentType Nothing fragmentPosition allowedTypes fragment
    >>= onlyValidateFrag validate

validateFragments ::
  (Fragment RAW -> FragmentValidator RAW (SelectionSet VALID)) ->
  FragmentValidator RAW (Fragments VALID)
validateFragments f = askFragments >>= traverse (onlyValidateFrag f)

onlyValidateFrag ::
  (Fragment RAW -> FragmentValidator s (SelectionSet VALID)) ->
  Fragment RAW ->
  FragmentValidator s (Fragment VALID)
onlyValidateFrag validate f@Fragment {..} =
  Fragment
    fragmentName
    fragmentType
    fragmentPosition
    <$> validate f <*> validateFragmentDirectives fragmentDirectives

validateFragmentDirectives :: Directives RAW -> FragmentValidator s (Directives VALID)
validateFragmentDirectives _ = pure empty --TODO: validate fragment directives

castFragmentType ::
  Maybe FragmentName ->
  Position ->
  [TypeName] ->
  Fragment s ->
  FragmentValidator s1 (Fragment s)
castFragmentType key position typeMembers fragment@Fragment {fragmentType}
  | fragmentType `elem` typeMembers = pure fragment
  | otherwise = throwError $ cannotBeSpreadOnType key fragmentType position typeMembers

resolveSpread :: [TypeName] -> Ref FragmentName -> FragmentValidator s (Fragment s)
resolveSpread allowedTargets ref@Ref {refName, refPosition} =
  askFragments
    >>= selectKnown ref
    >>= castFragmentType (Just refName) refPosition allowedTargets

selectFragmentType :: Fragment RAW -> FragmentValidator s (TypeDefinition OBJECT VALID)
selectFragmentType fr@Fragment {fragmentType, fragmentPosition} = withScope (setPosition fragmentPosition) $
  do
    typeDef <- __askType fragmentType
    constraint ONLY_OBJECT fr typeDef
