package enum RosettaState: Equatable {
  case unchecked
  case checking
  case missing
  case installing
  case available
  case failed(String)
}
