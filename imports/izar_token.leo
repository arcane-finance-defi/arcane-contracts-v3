program izar_token.aleo {
    record IzarToken {
        private owner: address,
        private id: u64,
        private amount: u64
    }

    transition transfer_public(public to: address, public amount: u64) {
        return;
    }

    transition transfer_private(private input: IzarToken, private to: address, private amount: u64) -> (IzarToken, IzarToken) {
        let output: IzarToken = IzarToken {
            owner: to, 
            id: input.id,
            amount: amount
        };
        let change: IzarToken = IzarToken {
            owner: input.owner,
            id: input.id,
            amount: input.amount - amount,
        };
        return (output, change);
    }

    transition transfer_private_to_public(private input: IzarToken, public to: address, public amount: u64) -> IzarToken {
        return input;
    }

    // self.caller balance is debited in finalize
    transition transfer_public_to_private(public to: address, public token_id: u64, public amount: u64) -> IzarToken {
        return IzarToken {
            owner: to, 
            id: token_id,
            amount: amount
        };
    }


}