#define STATIC_ERLANG_NIF 1

#include <erl_nif.h>
#include <stdio.h>
#include <string.h>
#include <math.h> 


/*
--------------------------------------------------------------------|
            ------------------------------                          |
            |           INIT FC          |                          |
            ------------------------------                          |
--------------------------------------------------------------------|
*/


ERL_NIF_TERM atom_nok;
ERL_NIF_TERM numerl_atom_true;
ERL_NIF_TERM numerl_atom_false;
ERL_NIF_TERM atom_matrix;
const int CSTE_TIMESLICE = 5;

ErlNifResourceType *MULT_YIELDING_ARG = NULL;

int numerl_load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info){
    atom_nok = enif_make_atom(env, "nok\0");
    numerl_atom_true = enif_make_atom(env, "true\0");
    numerl_atom_false = enif_make_atom(env, "false\0");
    atom_matrix = enif_make_atom(env, "matrix\0");
    return 0;
}

int upgrade(ErlNifEnv* caller_env, void** priv_data, void** old_priv_data, ERL_NIF_TERM load_info){
    return 0;
}

//Gives easier access to an ErlangBinary containing a matrix.
typedef struct{
    int n_rows;
    int n_cols;
    
    //Content of the matrix, in row major format.
    double* content;

    //Erlang binary containing the matrix.
    ErlNifBinary bin;
} Matrix;


//Access asked coordinates of matrix
double* matrix_at(int col, int row, Matrix m){
    return &m.content[row*m.n_cols + col];
}

//Allocates memory space of for matrix of dimensions n_rows, n_cols.
//The matrix_content can be modified, until a call to array_to_erl.
//Matrix content is stored in row major format.
Matrix matrix_alloc(int n_rows, int n_cols){
    ErlNifBinary bin;

    enif_alloc_binary(sizeof(double)*n_rows*n_cols, &bin);

    Matrix matrix;
    matrix.n_cols = n_cols;
    matrix.n_rows = n_rows;
    matrix.bin = bin;
    matrix.content = (double*) bin.data;

    return matrix;
}

//Creates a duplicate of a matrix.
//This duplicate can be modified until uploaded.
Matrix matrix_dup(Matrix m){
    Matrix d = matrix_alloc(m.n_rows, m.n_cols);
    memcpy(d.content, m.content, d.bin.size);
    return d;
}

//Free an allocated matrix that was not sent back to Erlang.
void matrix_free(Matrix m){
    enif_release_binary(&m.bin);
}

//Constructs a matrix erlang term.
//No modifications can be made afterwards to the matrix.
ERL_NIF_TERM matrix_to_erl(ErlNifEnv* env, Matrix m){
    ERL_NIF_TERM term = enif_make_binary(env, &m.bin);
    return enif_make_tuple4(env, atom_matrix, enif_make_int(env,m.n_rows), enif_make_int(env,m.n_cols), term);
}

int enif_is_matrix(ErlNifEnv* env, ERL_NIF_TERM term){
    int arity;
    const ERL_NIF_TERM* content;

    if(!enif_is_tuple(env, term))
        return 0;

    enif_get_tuple(env, term, &arity, &content);
    if(arity != 4)
        return 0;
    
    if(content[0] != atom_matrix
        || !enif_is_number(env, content[1])
        || !enif_is_number(env, content[2])
        || !enif_is_binary(env, content[3]))
            
            return 0;
    return 1;
}

//Reads an erlang term as a matrix.
//As such, no modifications can be made to the red matrix.
//Returns true if it was possible to read a matrix, false otherwise
int enif_get_matrix(ErlNifEnv* env, ERL_NIF_TERM term, Matrix *dest){
    
    int arity;
    const ERL_NIF_TERM* content;

    if(!enif_is_tuple(env, term))
        return 0;

    enif_get_tuple(env, term, &arity, &content);
    if(arity != 4)
        return 0;
    
    if(content[0] != atom_matrix
        || !enif_get_int(env, content[1], &dest->n_rows)
        || !enif_get_int(env, content[2], &dest->n_cols)
        || !enif_inspect_binary(env, content[3], &dest->bin))
    {
        return 0;
    }

    dest->content = (double*) (dest->bin.data);    
    return 1;
}

//Used to translate at once a number of ERL_NIF_TERM.
//Data types are inferred via content of format string:
//  n: number (int or double) translated to double.
//  m: matrix
//  i: int
int enif_get(ErlNifEnv* env, const ERL_NIF_TERM* erl_terms, const char* format, ...){
    va_list valist;
    va_start(valist, format);
    int valid = 1;

    while(valid && *format != '\0'){
        switch(*format++){
            case 'n':
                //Read a number as a double.
                ;
                double *d = va_arg(valist, double*);
                int i;
                if(!enif_get_double(env, *erl_terms, d))
                    if(enif_get_int(env, *erl_terms, &i))
                        *d = (double) i;
                    else valid = 0;
                break;

            case 'm':
                //Reads a matrix.
                valid = enif_get_matrix(env, *erl_terms, va_arg(valist, Matrix*));
                break;
            
            case 'i':
                //Reads an int.
                valid = enif_get_int(env, *erl_terms, va_arg(valist, int*));
                break;
            
            default:
                //Unknown type... give an error.
                valid = 0;
                break;
        }
        erl_terms ++;
    }

    va_end(valist);
    return valid;
}


//----------------------------------------------------------------------------------------------------|
//                        ------------------------------------------                                  |
//                        |                   NIFS                 |                                  |
//                        ------------------------------------------                                  |
//----------------------------------------------------------------------------------------------------|


//@arg 0: List of Lists of numbers.
//@return: Matrix of dimension
ERL_NIF_TERM nif_matrix(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){
    unsigned n_rows, line_length, dest = 0, n_cols = -1;
    ERL_NIF_TERM list = argv[0], row, elem;
    Matrix m;

    //Reading incoming matrix.
    if(!enif_get_list_length(env, list, &n_rows) && n_rows > 0)
        return enif_make_badarg(env);

    for(int i = 0; enif_get_list_cell(env, list, &row, &list); i++){
        if(!enif_get_list_length(env, row, &line_length)) 
            return enif_make_badarg(env);
        
        if(n_cols == -1){
            //Allocate binary, make matrix accessor.
            n_cols = line_length;
            m = matrix_alloc(n_rows,n_cols);
        }

        if(n_cols != line_length)
            return enif_make_badarg(env);

        for(int j = 0; enif_get_list_cell(env, row, &elem, &row); j++){
            if(!enif_get_double(env, elem, &m.content[dest])){
                int i;
                if(enif_get_int(env, elem, &i)){
                    m.content[dest] = (double) i;
                }
                else{
                    return enif_make_badarg(env);
                }
            }
            dest++;
        }
    }
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return matrix_to_erl(env, m);
}

#define PRECISION 10

//Used for debug purpose.
void debug_write(char info[]){
    FILE* fp = fopen("debug.txt", "a");
    fprintf(fp, info);
    fprintf(fp, "\n");
    fclose(fp);
}

void debug_write_matrix(Matrix m){
    char *content = enif_alloc(sizeof(char)*((2*m.n_cols-1)*m.n_rows*PRECISION + m.n_rows*2 + 3));
    content[0] = '[';
    content[1] = '\0';
    char converted[PRECISION];

    for(int i=0; i<m.n_rows; i++){
        strcat(content, "[");
        for(int j = 0; j<m.n_cols; j++){
            snprintf(converted, PRECISION-1, "%.5lf", m.content[i*m.n_cols+j]);
            strcat(content, converted);
            if(j != m.n_cols-1)
                strcat(content, " ");
        }
        strcat(content, "]");
    }
    strcat(content, "]");
    debug_write(content);
    enif_free(content);

}


//@arg 0: matrix.
//@arg 1: int, coord m: row
//@arg 2: int, coord n: col
//@return: double, at cord Matrix(m,n).
ERL_NIF_TERM nif_get(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]){
    int m,n;
    Matrix matrix;

    if(!enif_get(env, argv, "iim", &m, &n, &matrix))
        return enif_make_badarg(env);
    m--, n--;

    if(m < 0 || m >= matrix.n_rows || n < 0 || n >= matrix.n_cols)
        return enif_make_badarg(env);

    int index = m*matrix.n_cols+n;
    return enif_make_double(env, matrix.content[index]);
}

ERL_NIF_TERM nif_at(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]){
    int n;
    Matrix matrix;

    if(!enif_get(env, argv, "mi", &matrix, &n))
        return enif_make_badarg(env);
    n--;

    if( n < 0 || n >= matrix.n_cols * matrix.n_rows)
        return enif_make_badarg(env);

    return enif_make_double(env, matrix.content[n]);
}

//Matrix to flattened list of ints
ERL_NIF_TERM nif_mtfli(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]){
    Matrix M;
    if(!enif_get(env, argv, "m", &M)){
        return enif_make_badarg(env);
    }

    int n_elems = M.n_cols * M.n_rows;
    ERL_NIF_TERM *arr = enif_alloc(sizeof(ERL_NIF_TERM)*n_elems);
    for(int i = 0; i<n_elems; i++){
        arr[i] = enif_make_int(env, (int)M.content[i]);
    }
    
    ERL_NIF_TERM result = enif_make_list_from_array(env, arr, n_elems);
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    enif_free(arr);
    return result;
}

//Matrix to flattened list of ints
ERL_NIF_TERM nif_mtfl(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]){
    Matrix M;
    if(!enif_get(env, argv, "m", &M)){
        return enif_make_badarg(env);
    }

    int n_elems = M.n_cols * M.n_rows;
    ERL_NIF_TERM *arr = enif_alloc(sizeof(ERL_NIF_TERM)*n_elems);
    for(int i = 0; i<n_elems; i++){
        arr[i] = enif_make_double(env, M.content[i]);
    }
    
    ERL_NIF_TERM result = enif_make_list_from_array(env, arr, n_elems);
    enif_free(arr);
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return result;
}

//Equal all doubles
//Compares whether all doubles are approximately the same.
int equal_ad(double* a, double* b, int size){
    for(int i = 0; i<size; i++){
        if(fabs(a[i] - b[i])> 1e-6)
            return 0;
    }
    return 1;
}

//@arg 0: Array.
//@arg 1: Array.
//@return: true if arrays share content, false if they have different content || size..
ERL_NIF_TERM nif_equals(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){
    Matrix a,b;

    if(!enif_get(env, argv, "mm", &a, &b))
        return numerl_atom_false;

    //Compare number of columns and rows
    if((a.n_cols != b.n_cols || a.n_rows != b.n_rows))
        return numerl_atom_false;

    //Compare content of arrays
    if(!equal_ad(a.content, b.content, a.n_cols*a.n_rows))
        return numerl_atom_false;
    
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return numerl_atom_true;
}


//@arg 0: int.
//@arg 1: Array.
//@return: returns an array, containing requested row.
ERL_NIF_TERM nif_row(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]){
    int row_req;
    Matrix matrix;
    if(!enif_get(env, argv, "im", &row_req, &matrix))
        return enif_make_badarg(env);

    row_req--;
    if(row_req<0 || row_req >= matrix.n_rows)
        return enif_make_badarg(env);

    Matrix row = matrix_alloc(1, matrix.n_cols);
    memcpy(row.content, matrix.content + (row_req * matrix.n_cols), matrix.n_cols*sizeof(double));
    
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return matrix_to_erl(env, row);
}


//@arg 0: int.
//@arg 1: Array.
//@return: returns an array, containing requested col.
ERL_NIF_TERM nif_col(ErlNifEnv * env, int argc, const ERL_NIF_TERM argv[]){
    int col_req;
    Matrix matrix;
    if(!enif_get(env, argv, "im", &col_req, &matrix))
        return enif_make_badarg(env);

    col_req--;    
    if(col_req<0 || col_req >= matrix.n_cols)
        return enif_make_badarg(env);


    Matrix col = matrix_alloc(matrix.n_rows, 1);

    for(int i = 0; i < matrix.n_rows; i++){
        col.content[i] = matrix.content[i * matrix.n_rows + col_req];
    }
    
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return matrix_to_erl(env, col);
}


//@arg 0: int.
//@arg 1: int.
//@return: empty Matrix of requested dimension..
ERL_NIF_TERM nif_zeros(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){
    int m,n;
    if(!enif_get(env, argv, "ii", &m, &n))
        return enif_make_badarg(env);

    Matrix a = matrix_alloc(m,n);
    memset(a.content, 0, sizeof(double)*m*n);
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return matrix_to_erl(env, a);
}

//@arg 0: int.
//@arg 1: int.
//@return: empty matrix of dimension [arg 0, arg 1]..
ERL_NIF_TERM nif_eye(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){
    int m;
    if(!enif_get_int(env, argv[0], &m))
        return enif_make_badarg(env);
    
    if(m <= 0)
        return enif_make_badarg(env);

    Matrix a = matrix_alloc(m,m);
    memset(a.content, 0, sizeof(double)*m*m);
    for(int i = 0; i<m; i++){
        a.content[i*m+i] = 1.0;
    }
    enif_consume_timeslice(env, CSTE_TIMESLICE);
    return matrix_to_erl(env, a);
}

//Either element-wise multiplication, or multiplication of a matrix by a number.
ERL_NIF_TERM nif_mult(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){

    Matrix a,b;
    double c;
    
    if(enif_get(env, argv, "mn", &a, &c)){
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i<a.n_cols*a.n_rows; i++){
            d.content[i] = a.content[i] * c;
        }
        
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }
    else 
    if(enif_get(env, argv, "mm", &a, &b)
            && a.n_rows*a.n_cols == b.n_rows*b.n_cols){
        
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i < a.n_rows*a.n_cols; i++){
            d.content[i] = a.content[i] * b.content[i];
        }
        
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }
    
    return enif_make_badarg(env);
}


//Either element-wise addition, or addition of a matrix by a number.
ERL_NIF_TERM nif_add(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){

    Matrix a,b;
    double c;
    
    if(enif_get(env, argv, "mn", &a, &c)){
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i<a.n_cols*a.n_rows; i++){
            d.content[i] = a.content[i] + c;
        }
        
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }
    else 
    if(enif_get(env, argv, "mm", &a, &b)
            && a.n_rows*a.n_cols == b.n_rows*b.n_cols){
        
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i < a.n_rows*a.n_cols; i++){
            d.content[i] = a.content[i] + b.content[i];
        }
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }

    return enif_make_badarg(env);
}


//Either element-wise subtraction, or subtraction of a matrix by a number.
ERL_NIF_TERM nif_sub(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){

    Matrix a,b;
    double c;
    
    if(enif_get(env, argv, "mn", &a, &c)){
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i<a.n_cols*a.n_rows; i++){
            d.content[i] = a.content[i] - c;
        }
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }
    else 
    if(enif_get(env, argv, "mm", &a, &b)
            && a.n_rows*a.n_cols == b.n_rows*b.n_cols){
        
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i < a.n_rows*a.n_cols; i++){
            d.content[i] = a.content[i] - b.content[i];
        }
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }

    return enif_make_badarg(env);
}


//Either element-wise division, or division of a matrix by a number.
ERL_NIF_TERM nif_divide(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){

    Matrix a,b;
    double c;
    
    if(enif_get(env, argv, "mn", &a, &c)){
        
        if(c!=0.0){
            Matrix d = matrix_alloc(a.n_rows, a.n_cols);

            for(int i = 0; i<a.n_cols*a.n_rows; i++){
                d.content[i] = a.content[i] / c;
            }
            enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
            return matrix_to_erl(env, d);
        }
    }
    else if(enif_get(env, argv, "mm", &a, &b)
            && a.n_rows*a.n_cols == b.n_rows*b.n_cols){
        
        Matrix d = matrix_alloc(a.n_rows, a.n_cols);

        for(int i = 0; i < a.n_rows*a.n_cols; i++){
            if(b.content[i] == 0.0){
                return enif_make_badarg(env);
            }
            else{
                d.content[i] = a.content[i] / b.content[i];
            }
        }
        enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
        return matrix_to_erl(env, d);
    }

    return enif_make_badarg(env);
}


//Transpose of a matrix.
Matrix tr(Matrix a){
    Matrix result = matrix_alloc(a.n_cols ,a.n_rows);

    for(int j = 0; j < a.n_rows; j++){
        for(int i = 0; i < a.n_cols; i++){
            result.content[i*result.n_cols+j] = a.content[j*a.n_cols+i];
        }
    }
    return result;
}
ERL_NIF_TERM nif_transpose(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){

    Matrix a;
    if(!enif_get_matrix(env, argv[0], &a))
        return enif_make_badarg(env);
    enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
    return matrix_to_erl(env, tr(a));
}


//arg0: Matrix.
ERL_NIF_TERM nif_inv(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){
    
    Matrix a;
    if(!enif_get_matrix(env, argv[0], &a))
        return enif_make_badarg(env);

    if(a.n_cols != a.n_rows){
        return atom_nok;
    }
    int n_cols = 2*a.n_cols;

    double* gj = (double*) enif_alloc(n_cols*a.n_rows*sizeof(double));
    for(int i=0; i<a.n_rows; i++){
        memcpy(gj+i*n_cols, a.content+i*a.n_cols, sizeof(double)*a.n_cols);
        memset(gj+i*n_cols + a.n_cols, 0, sizeof(double)*a.n_cols);
        gj[i*n_cols + a.n_cols + i] = 1.0;
    }

    //Elimination de Gauss Jordan:
    //https://fr.wikipedia.org/wiki/%C3%89limination_de_Gauss-Jordan
   
    //Row of last found pivot
    int r = -1;
    //j for all indexes of column
    for(int j=0; j<a.n_cols; j++){

        //Find the row of the maximum in column j
        int pivot_row = -1;
        for(int cur_row=r; cur_row<a.n_rows; cur_row++){
            if(pivot_row<0 || fabs(gj[cur_row*n_cols + j]) > fabs(gj[pivot_row*n_cols+j])){
                pivot_row = cur_row;
            }
        }
        double pivot_value = gj[pivot_row*n_cols+j];

        if(pivot_value != 0){
            r++;
            for(int cur_col=0; cur_col<n_cols; cur_col++){
                gj[cur_col+pivot_row*n_cols] /= pivot_value;
            }
            gj[pivot_row*n_cols + j] = 1.0; //make up for rounding errors

            //Do we need to swap?
            if(pivot_row != r){
                for(int i = 0; i<n_cols; i++){
                    double cpy = gj[pivot_row*n_cols+i];
                    gj[pivot_row*n_cols+i]= gj[r*n_cols+i];
                    gj[r*n_cols+i] = cpy;
                }
            }

            //We can simplify all the rows
            for(int i=0; i<a.n_rows; i++){
                if(i!=r){
                    double factor = gj[i*n_cols+j];
                    for(int col=0; col<n_cols; col++){
                        gj[col+i*n_cols] -= gj[col+r*n_cols]*factor;
                    }
                    gj[i*n_cols+j] = 0.0;    //make up for rounding errors
                }
            }
        }

    }
    
    Matrix inv = matrix_alloc(a.n_rows, a.n_cols);
    for(int l=0; l<inv.n_rows; l++){
        int line_start = l*n_cols + a.n_cols;
        memcpy(inv.content + inv.n_cols*l, gj + line_start, sizeof(double)*inv.n_cols);
    }

    enif_free(gj);
    enif_consume_timeslice(env, a.n_cols*a.n_rows / 100);
    return matrix_to_erl(env, inv);
}


//Arguments: double alpha, matrix A, matrix B, double beta, matrix C
ERL_NIF_TERM nif_dgemm(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]){
    Matrix A, B;

    if(!enif_get(env, argv, "mm", &A, &B)
            || A.n_cols != B.n_rows){

        return enif_make_badarg(env);
    }
    
    //debug_write_matrix(A);
    //debug_write_matrix(B);

    int n_rows = A.n_rows;
    int n_cols = B.n_cols;

    if(A.n_cols != B.n_rows)
        return atom_nok;

    Matrix result = matrix_alloc(n_rows, n_cols);
    memset(result.content, 0.0, n_rows*n_cols * sizeof(double));

    //Will this create a mem leak?
    Matrix b_tr = tr(B); 
    
    for(int i = 0; i < n_rows; i++){
        for(int j = 0; j < n_cols; j++){
           for(int k = 0; k<A.n_cols; k++){
               result.content[j+i*result.n_cols] += A.content[k+i*A.n_cols] * b_tr.content[k+j*b_tr.n_cols];
           }
        }
    }

    enif_release_binary(&b_tr.bin); // might need to replace by enif_release_binary(&m.bin);

    enif_consume_timeslice(env, A.n_cols*A.n_rows*B.n_rows / 100);
    return matrix_to_erl(env, result);
}

ErlNifFunc nif_funcs[] = {
    {"matrix", 1, nif_matrix},
    {"get", 3, nif_get},
    {"at", 2, nif_at},
    {"mtfli", 1, nif_mtfli},
    {"mtfl", 1, nif_mtfl},
    {"equals", 2, nif_equals},
    {"row", 2, nif_row},
    {"col", 2, nif_col},
    {"zeros", 2, nif_zeros},
    {"eye", 1, nif_eye},
    {"mult", 2, nif_mult},
    {"add",  2, nif_add},
    {"sub",  2, nif_sub},
    {"divide", 2, nif_divide},
    {"transpose", 1, nif_transpose},
    {"inv", 1, nif_inv},
    
    {"dot", 2, nif_dgemm}
};

ERL_NIF_INIT(numerl, nif_funcs, numerl_load, NULL, upgrade, NULL)