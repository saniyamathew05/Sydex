class Customer {
  final String id;
  final String businessName;
  final String location;
  final String phone;
  final double openingBalance;

  Customer({
    required this.id,
    required this.businessName,
    required this.location,
    required this.phone,
    this.openingBalance = 0,
  });
}
