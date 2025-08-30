import 'dart:typed_data';
import 'dart:convert';

import 'package:price_service_client/price_service_client.dart';

class SuiPriceServiceConnection extends PriceServiceConnection {
  SuiPriceServiceConnection(super.endpoint, {super.config});

  /// Gets price update data (either batch price attestation VAAs or accumulator messages, depending on the chosen endpoint), which then
  /// can be submitted to the Pyth contract to update the prices. This will throw an axios error if there is a network problem or
  /// the price service returns a non-ok response (e.g: Invalid price ids)
  Future<List<Uint8List>> getPriceFeedsUpdateData(List<String> priceIds) async {
    // Fetch the latest price feed update VAAs from the price service
    final latestVaas = await getLatestVaas(priceIds);
    return latestVaas.map((vaa) => base64.decode(vaa)).toList();
  }
}
