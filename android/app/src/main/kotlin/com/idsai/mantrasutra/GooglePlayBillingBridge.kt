package com.idsai.mantrasutra

import android.app.Activity
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Narrow Android-only bridge for one-time multi-product purchases. */
class GooglePlayBillingBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private val productDetails = mutableMapOf<String, ProductDetails>()
    private var connecting = false
    private val readyCallbacks = mutableListOf<(BillingResult?) -> Unit>()

    private val billingClient = BillingClient.newBuilder(activity)
        .setListener { result, purchases ->
            eventSink?.success(
                mapOf(
                    "responseCode" to result.responseCode,
                    "debugMessage" to result.debugMessage,
                    "purchases" to (purchases?.map(::purchaseMap) ?: emptyList<Map<String, Any?>>()),
                ),
            )
        }
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder().enableOneTimeProducts().build(),
        )
        .build()

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        eventSink = null
        billingClient.endConnection()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                withReady { billingResult ->
                if (billingResult == null || billingResult.responseCode == BillingClient.BillingResponseCode.OK) {
                    result.success(true)
                } else {
                    result.error("billing_unavailable", billingResult.debugMessage, billingResult.responseCode)
                }
            }
            }
            "queryProducts" -> queryProducts(call.argument<List<String>>("productIds").orEmpty(), result)
            "launchMultiProductPurchase" -> launchMultiProductPurchase(
                call.argument<List<String>>("productIds").orEmpty(),
                call.argument<String>("obfuscatedAccountId").orEmpty(),
                result,
            )
            "queryOutstandingPurchases" -> queryOutstandingPurchases(result)
            "consumePurchase" -> consumePurchase(
                call.argument<String>("purchaseToken").orEmpty(),
                result,
            )
            else -> result.notImplemented()
        }
    }

    private fun withReady(callback: (BillingResult?) -> Unit) {
        if (billingClient.isReady) {
            callback(null)
            return
        }
        readyCallbacks.add(callback)
        if (connecting) return
        connecting = true
        val listener = object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                connecting = false
                val callbacks = readyCallbacks.toList()
                readyCallbacks.clear()
                callbacks.forEach { callback ->
                    try {
                        callback(result)
                    } catch (_: Throwable) {
                        // One consumer must not prevent the remaining readiness callbacks.
                    }
                }
            }

            override fun onBillingServiceDisconnected() {
                connecting = false
            }
        }
        try {
            billingClient.startConnection(listener)
        } catch (error: Throwable) {
            connecting = false
            throw error
        }
    }

    private fun queryProducts(ids: List<String>, channelResult: MethodChannel.Result) {
        if (ids.isEmpty()) {
            channelResult.success(emptyList<Map<String, Any?>>())
            return
        }
        withReady { setup ->
            if (setup != null && setup.responseCode != BillingClient.BillingResponseCode.OK) {
                channelResult.error("billing_unavailable", setup.debugMessage, setup.responseCode)
                return@withReady
            }
            val products = ids.distinct().map {
                QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(it)
                    .setProductType(BillingClient.ProductType.INAPP)
                    .build()
            }
            billingClient.queryProductDetailsAsync(
                QueryProductDetailsParams.newBuilder().setProductList(products).build(),
            ) { billingResult, queryResult ->
                val details = queryResult.productDetailsList
                if (billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                    channelResult.error("product_query_failed", billingResult.debugMessage, billingResult.responseCode)
                    return@queryProductDetailsAsync
                }
                details.forEach { productDetails[it.productId] = it }
                channelResult.success(details.map(::productMap))
            }
        }
    }

    private fun launchMultiProductPurchase(
        productIds: List<String>,
        obfuscatedAccountId: String,
        channelResult: MethodChannel.Result,
    ) {
        if (productIds.isEmpty() || productIds.any(String::isBlank) || obfuscatedAccountId.isBlank()) {
            channelResult.error("invalid_purchase", "Products and account ID are required.", null)
            return
        }
        if (productIds.distinct().size != productIds.size) {
            channelResult.error("duplicate_products", "Google Play product IDs must be unique.", null)
            return
        }
        withReady { setup ->
            if (setup != null && setup.responseCode != BillingClient.BillingResponseCode.OK) {
                channelResult.error("billing_unavailable", setup.debugMessage, setup.responseCode)
                return@withReady
            }
            val cached = productIds.mapNotNull(productDetails::get)
            if (cached.size == productIds.size) {
                launchLoadedProducts(cached, obfuscatedAccountId, channelResult)
                return@withReady
            }
            val products = productIds.map { productId ->
                QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(productId)
                    .setProductType(BillingClient.ProductType.INAPP)
                    .build()
            }
            billingClient.queryProductDetailsAsync(
                QueryProductDetailsParams.newBuilder().setProductList(products).build(),
            ) { billingResult, queryResult ->
                val details = queryResult.productDetailsList
                details.forEach { productDetails[it.productId] = it }
                val loadedById = details.associateBy(ProductDetails::getProductId)
                val loaded = productIds.mapNotNull(loadedById::get)
                if (billingResult.responseCode != BillingClient.BillingResponseCode.OK || loaded.size != productIds.size) {
                    channelResult.error("product_unavailable", "Google Play product is unavailable.", billingResult.responseCode)
                    return@queryProductDetailsAsync
                }
                launchLoadedProducts(loaded, obfuscatedAccountId, channelResult)
            }
        }
    }

    private fun launchLoadedProducts(
        details: List<ProductDetails>,
        obfuscatedAccountId: String,
        channelResult: MethodChannel.Result,
    ) {
        val productParams = details.map { detail ->
            BillingFlowParams.ProductDetailsParams.newBuilder()
                .setProductDetails(detail)
                .build()
        }
        val billingResult = billingClient.launchBillingFlow(
            activity,
            BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(productParams)
                .setObfuscatedAccountId(obfuscatedAccountId)
                .build(),
        )
        channelResult.success(
            mapOf(
                "responseCode" to billingResult.responseCode,
                "debugMessage" to billingResult.debugMessage,
            ),
        )
    }

    private fun consumePurchase(token: String, channelResult: MethodChannel.Result) {
        if (token.isBlank()) {
            channelResult.error("invalid_purchase_token", "Purchase token is required.", null)
            return
        }
        withReady { setup ->
            if (setup != null && setup.responseCode != BillingClient.BillingResponseCode.OK) {
                channelResult.error("billing_unavailable", setup.debugMessage, setup.responseCode)
                return@withReady
            }
            billingClient.consumeAsync(
                ConsumeParams.newBuilder().setPurchaseToken(token).build(),
            ) { billingResult, _ ->
                channelResult.success(
                    mapOf(
                        "responseCode" to billingResult.responseCode,
                        "debugMessage" to billingResult.debugMessage,
                    ),
                )
            }
        }
    }

    private fun queryOutstandingPurchases(channelResult: MethodChannel.Result) {
        withReady { setup ->
            if (setup != null && setup.responseCode != BillingClient.BillingResponseCode.OK) {
                channelResult.error("billing_unavailable", setup.debugMessage, setup.responseCode)
                return@withReady
            }
            billingClient.queryPurchasesAsync(
                QueryPurchasesParams.newBuilder()
                    .setProductType(BillingClient.ProductType.INAPP)
                    .build(),
            ) { billingResult, purchases ->
                if (billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
                    channelResult.error("purchase_query_failed", billingResult.debugMessage, billingResult.responseCode)
                } else {
                    channelResult.success(purchases.map(::purchaseMap))
                }
            }
        }
    }

    private fun productMap(details: ProductDetails): Map<String, Any?> {
        val offer = details.oneTimePurchaseOfferDetails
        return mapOf(
            "productId" to details.productId,
            "name" to details.name,
            "description" to details.description,
            "formattedPrice" to offer?.formattedPrice,
            "priceAmountMicros" to offer?.priceAmountMicros,
            "priceCurrencyCode" to offer?.priceCurrencyCode,
        )
    }

    private fun purchaseMap(purchase: com.android.billingclient.api.Purchase): Map<String, Any?> =
        mapOf(
            "purchaseToken" to purchase.purchaseToken,
            "products" to purchase.products,
            "purchaseState" to purchase.purchaseState,
            "orderId" to purchase.orderId,
            "isAcknowledged" to purchase.isAcknowledged,
            "quantity" to purchase.quantity,
            "purchaseTime" to purchase.purchaseTime,
            "obfuscatedAccountId" to purchase.accountIdentifiers?.obfuscatedAccountId,
        )

}
