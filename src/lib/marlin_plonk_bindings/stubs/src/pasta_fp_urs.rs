use mina_curves::pasta::{vesta::Affine as GAffine, fp::Fp};
use algebra::{One, Zero};
use ff_fft::{DensePolynomial, EvaluationDomain, Evaluations};

use commitment_dlog::{
    commitment::{b_poly_coefficients, PolyComm},
    srs::SRS,
};

use std::{
    fs::{File, OpenOptions},
    io::{BufReader, BufWriter, Seek, SeekFrom::Start},
    rc::Rc,
};

use crate::caml_pointer::{self, CamlPointer};

pub type CamlPastaFpUrs = CamlPointer<Rc<SRS<GAffine>>>;

#[ocaml::func]
pub fn caml_pasta_fp_urs_create(depth: ocaml::Int) -> CamlPastaFpUrs {
    caml_pointer::create(Rc::new(SRS::create(depth as usize)))
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_write(
    append: Option<bool>,
    urs: CamlPastaFpUrs,
    path: String,
) -> Result<(), ocaml::Error> {
    match OpenOptions::new().append(append.unwrap_or(true)).open(path) {
        Err(_) => Err(ocaml::Error::invalid_argument("caml_pasta_fp_urs_write")
            .err()
            .unwrap()),
        Ok(file) => {
            let file = BufWriter::new(file);
            let urs: &SRS<GAffine> = &*urs;
            let _ = (*urs).write(file);
            Ok(())
        }
    }
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_read(
    offset: Option<ocaml::Int>,
    path: String,
) -> Result<Option<CamlPastaFpUrs>, ocaml::Error> {
    match File::open(path) {
        Err(_) => Err(ocaml::Error::invalid_argument("caml_pasta_fp_urs_read")
            .err()
            .unwrap()),
        Ok(file) => {
            let mut file = BufReader::new(file);
            match offset {
                Some(offset) => {
                    file.seek(Start(offset as u64))?;
                }
                None => (),
            };
            match SRS::<GAffine>::read(file) {
                Err(_) => Ok(None),
                Ok(urs) => Ok(Some(caml_pointer::create(Rc::new(urs)))),
            }
        }
    }
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_lagrange_commitment(
    urs: CamlPastaFpUrs,
    domain_size: ocaml::Int,
    i: ocaml::Int,
) -> Result<PolyComm<GAffine>, ocaml::Error> {
    match EvaluationDomain::<Fp>::new(domain_size as usize) {
        None => Err(
            ocaml::Error::invalid_argument("caml_pasta_fp_urs_lagrange_commitment")
                .err()
                .unwrap(),
        ),
        Some(x_domain) => {
            let evals = (0..domain_size)
                .map(|j| if i == j { Fp::one() } else { Fp::zero() })
                .collect();
            let p = Evaluations::<Fp>::from_vec_and_domain(evals, x_domain).interpolate();
            Ok((*urs).commit_non_hiding(&p, None).into())
        }
    }
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_commit_evaluations(
    urs: CamlPastaFpUrs,
    domain_size: ocaml::Int,
    evals: Vec<Fp>,
) -> Result<PolyComm<GAffine>, ocaml::Error> {
    match EvaluationDomain::<Fp>::new(domain_size as usize) {
        None => Err(
            ocaml::Error::invalid_argument("caml_pasta_fp_urs_commit_evaluations")
                .err()
                .unwrap(),
        ),
        Some(x_domain) => {
            let evals = evals.into_iter().map(From::from).collect();
            let p = Evaluations::<Fp>::from_vec_and_domain(evals, x_domain).interpolate();
            Ok((*urs).commit_non_hiding(&p, None).into())
        }
    }
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_b_poly_commitment(
    urs: CamlPastaFpUrs,
    chals: Vec<Fp>,
) -> Result<PolyComm<GAffine>, ocaml::Error> {
    let chals: Vec<Fp> = chals.into_iter().map(From::from).collect();
    let coeffs = b_poly_coefficients(&chals);
    let p = DensePolynomial::<Fp>::from_coefficients_vec(coeffs);
    Ok((*urs).trim(chals.len()).commit_non_hiding(&p, None).into())
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_batch_accumulator_check(
    urs: CamlPastaFpUrs,
    comms: Vec<GAffine>,
    chals: Vec<Fp>,
) -> bool {
    crate::urs_utils::batch_dlog_accumulator_check(
        &*urs,
        &comms.into_iter().map(From::from).collect(),
        &chals.into_iter().map(From::from).collect(),
    )
}

#[ocaml::func]
pub fn caml_pasta_fp_urs_h(urs: CamlPastaFpUrs) -> GAffine {
    (*urs).h.into()
}
