{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE MonoLocalBinds     #-}
{-# LANGUAGE NamedFieldPuns     #-}
{-# LANGUAGE NoImplicitPrelude  #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE ViewPatterns       #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
-- | Implements a custom currency with a monetary policy that allows
--   the forging of a fixed amount of units.
module Plutus.Contracts.Currency(
      OneShotCurrency(..)
    , CurrencySchema
    , CurrencyError(..)
    , AsCurrencyError(..)
    , curPolicy
    -- * Actions etc
    , forgeContract
    , forgedValue
    , currencySymbol
    -- * Simple monetary policy currency
    , SimpleMPS(..)
    , forgeCurrency
    -- * Creating thread tokens
    , createThreadToken
    ) where

import           Control.Lens
import           Plutus.Contracts.PubKey (AsPubKeyError (..), PubKeyError)
import qualified Plutus.Contracts.PubKey as PK
import           PlutusTx.Prelude        hiding (Monoid (..), Semigroup (..))

import           Plutus.Contract         as Contract

import           Ledger                  (CurrencySymbol, PubKeyHash, TxId, TxOutRef (..), pubKeyHash,
                                          scriptCurrencySymbol, txId)
import qualified Ledger.Ada              as Ada
import qualified Ledger.Constraints      as Constraints
import qualified Ledger.Contexts         as V
import           Ledger.Scripts
import qualified PlutusTx                as PlutusTx

import qualified Ledger.Typed.Scripts    as Scripts
import           Ledger.Value            (AssetClass, TokenName, Value)
import qualified Ledger.Value            as Value

import           Data.Aeson              (FromJSON, ToJSON)
import qualified Data.Map                as Map
import           Data.Semigroup          (Last (..))
import           GHC.Generics            (Generic)
import qualified PlutusTx.AssocMap       as AssocMap
import           Prelude                 (Semigroup (..))
import qualified Prelude                 as Haskell
import           Schema                  (ToSchema)

{-# ANN module ("HLint: ignore Use uncurry" :: Haskell.String) #-}

-- | A currency that can be created exactly once
data OneShotCurrency = OneShotCurrency
  { curRefTransactionOutput :: (TxId, Integer)
  -- ^ Transaction input that must be spent when
  --   the currency is forged.
  , curAmounts              :: AssocMap.Map TokenName Integer
  -- ^ How many units of each 'TokenName' are to
  --   be forged.
  }
  deriving stock (Generic, Haskell.Show, Haskell.Eq)
  deriving anyclass (ToJSON, FromJSON)

PlutusTx.makeLift ''OneShotCurrency

currencyValue :: CurrencySymbol -> OneShotCurrency -> Value
currencyValue s OneShotCurrency{curAmounts = amts} =
    let
        values = map (\(tn, i) -> (Value.singleton s tn i)) (AssocMap.toList amts)
    in fold values

mkCurrency :: TxOutRef -> [(TokenName, Integer)] -> OneShotCurrency
mkCurrency (TxOutRef h i) amts =
    OneShotCurrency
        { curRefTransactionOutput = (h, i)
        , curAmounts              = AssocMap.fromList amts
        }

validate :: OneShotCurrency -> V.ScriptContext -> Bool
validate c@(OneShotCurrency (refHash, refIdx) _) ctx@V.ScriptContext{V.scriptContextTxInfo=txinfo} =
    let
        -- see note [Obtaining the currency symbol]
        ownSymbol = V.ownCurrencySymbol ctx

        forged = V.txInfoForge txinfo
        expected = currencyValue ownSymbol c

        -- True if the pending transaction forges the amount of
        -- currency that we expect
        forgeOK =
            let v = expected == forged
            in traceIfFalse "Value forged different from expected" v

        -- True if the pending transaction spends the output
        -- identified by @(refHash, refIdx)@
        txOutputSpent =
            let v = V.spendsOutput txinfo refHash refIdx
            in  traceIfFalse "Pending transaction does not spend the designated transaction output" v

    in forgeOK && txOutputSpent

curPolicy :: OneShotCurrency -> MonetaryPolicy
curPolicy cur = mkMonetaryPolicyScript $
    $$(PlutusTx.compile [|| \c -> Scripts.wrapMonetaryPolicy (validate c) ||])
        `PlutusTx.applyCode`
            PlutusTx.liftCode cur

{- note [Obtaining the currency symbol]

The currency symbol is the address (hash) of the validator. That is why
we can use 'Ledger.scriptAddress' here to get the symbol  in off-chain code,
for example in 'forgedValue'.

Inside the validator script (on-chain) we can't use 'Ledger.scriptAddress',
because at that point we don't know the hash of the script yet. That
is why we use 'V.ownCurrencySymbol', which obtains the hash from the
'PolicyCtx' value.

-}

-- | The 'Value' forged by the 'OneShotCurrency' contract
forgedValue :: OneShotCurrency -> Value
forgedValue cur = currencyValue (currencySymbol cur) cur

currencySymbol :: OneShotCurrency -> CurrencySymbol
currencySymbol = scriptCurrencySymbol . curPolicy

data CurrencyError =
    CurPubKeyError PubKeyError
    | CurContractError ContractError
    deriving stock (Haskell.Eq, Haskell.Show, Generic)
    deriving anyclass (ToJSON, FromJSON)

makeClassyPrisms ''CurrencyError

instance AsContractError CurrencyError where
    _ContractError = _CurContractError

instance AsPubKeyError CurrencyError where
    _PubKeyError = _CurPubKeyError

-- | @forge [(n1, c1), ..., (n_k, c_k)]@ creates a new currency with
--   @k@ token names, forging @c_i@ units of each token @n_i@.
--   If @k == 0@ then no value is forged. A one-shot monetary policy
--   script is used to ensure that no more units of the currency can
--   be forged afterwards.
forgeContract
    :: forall w s e.
    ( HasWriteTx s
    , HasTxConfirmation s
    , AsCurrencyError e
    )
    => PubKeyHash
    -> [(TokenName, Integer)]
    -> Contract w s e OneShotCurrency
forgeContract pk amounts = mapError (review _CurrencyError) $ do
    (txOutRef, txOutTx, pkInst) <- PK.pubKeyContract pk (Ada.lovelaceValueOf 1)
    let theCurrency = mkCurrency txOutRef amounts
        curVali     = curPolicy theCurrency
        lookups     = Constraints.monetaryPolicy curVali
                        <> Constraints.otherScript (Scripts.validatorScript pkInst)
                        <> Constraints.unspentOutputs (Map.singleton txOutRef txOutTx)
    let forgeTx = Constraints.mustSpendScriptOutput txOutRef unitRedeemer
                    <> Constraints.mustForgeValue (forgedValue theCurrency)
    tx <- submitTxConstraintsWith @Scripts.Any lookups forgeTx
    _ <- awaitTxConfirmed (txId tx)
    pure theCurrency

-- | Monetary policy for a currency that has a fixed amount of tokens issued
--   in one transaction
data SimpleMPS =
    SimpleMPS
        { tokenName :: TokenName
        , amount    :: Integer
        }
        deriving stock (Haskell.Eq, Haskell.Show, Generic)
        deriving anyclass (FromJSON, ToJSON, ToSchema)

type CurrencySchema =
    BlockchainActions
        .\/ Endpoint "Create native token" SimpleMPS

-- | Use 'forgeContract' to create the currency specified by a 'SimpleMPS'
forgeCurrency
    :: Contract (Maybe (Last OneShotCurrency)) CurrencySchema CurrencyError OneShotCurrency
forgeCurrency = do
    SimpleMPS{tokenName, amount} <- endpoint @"Create native token"
    ownPK <- pubKeyHash <$> ownPubKey
    cur <- forgeContract ownPK [(tokenName, amount)]
    tell (Just (Last cur))
    pure cur

-- | Create a thread token for a state machine
createThreadToken ::
    forall s w.
    ( HasOwnPubKey s
    , HasTxConfirmation s
    , HasWriteTx s
    )
    => Contract w s CurrencyError AssetClass
createThreadToken = do
    ownPK <- pubKeyHash <$> ownPubKey
    let tokenName :: TokenName = "thread token"
    s <- forgeContract ownPK [(tokenName, 1)]
    pure $ Value.assetClass (currencySymbol s) tokenName
