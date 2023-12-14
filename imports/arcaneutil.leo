
program arcaneutil.aleo {
    
    transition get_caller_address() -> address {
        let a: address = self.caller;
        return a;
    }

}